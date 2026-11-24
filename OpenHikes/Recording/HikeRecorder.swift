//
//  HikeRecorder.swift
//  OpenHikes
//
//  App-scoped live recording coordinator. The view may come and go; this
//  object owns Core Location delivery, the crash-safe journal, and the
//  persisted draft Hike, finalized in place by Stop.
//

import CoreLocation
import Foundation
import Observation
import OpenHikesData
import OpenHikesShared
import os
import SwiftData

@Observable
final class HikeRecorder: NSObject {
    nonisolated static let logger = Logger(
        subsystem: "OpenHikes",
        category: "HikeRecorder"
    )

    enum Phase: Equatable {
        case idle
        case recovering
        case waitingForFix
        case recording
        case paused
        case saving
        case failed(RecordingFailure)
    }

    enum RecoveryState: Equatable {
        case absent
        case resumed
        case needsDecision(RecordingRecoverySummary)
    }

    /// Nothing else here needs unwinding: every other task this recorder owns
    /// is either tied to a session that has already ended or is cancelled on
    /// the path that started it. ``powerStateObservation`` is the exception —
    /// it is deliberately lifetime-scoped rather than session-scoped, so this
    /// is the only place that ends it. Without this the loop would sit on its
    /// `PowerStateMonitor` until the next power-state change woke it up to
    /// discover its recorder was gone.
    nonisolated deinit { powerStateObservation?.cancel() }

    var phase: Phase = .idle
    var recoveryState: RecoveryState = .absent
    var sessionStartedAt: Date?
    var currentHike: Hike?

    let stats = RecordingStats()
    let trace = RecordingTrace()

    @ObservationIgnored let container: ModelContainer
    @ObservationIgnored let saveModelContext: (ModelContext) throws -> Void
    /// Where a discarded draft's photo files are erased from. The one seam a
    /// suite needs to watch that erase without writing into the host app's
    /// real photo directory.
    @ObservationIgnored let photoStore: HikePhotoStore
    @ObservationIgnored let source: any RecordingLocationSource
    @ObservationIgnored let elevationSource: (any RecordingElevationSource)?
    @ObservationIgnored let motionSource: (any RecordingMotionSource)?
    @ObservationIgnored let trailGraphProvider: (any TrailGraphProviding)?
    @ObservationIgnored let trailGraphRetryPolicy: TrailGraphPrefetchRetryPolicy
    @ObservationIgnored let trailGraphRetryJitter: @Sendable () -> Double
    @ObservationIgnored let distanceEvidenceSource: (any RecordingDistanceEvidenceSource)?
    /// Whether the radio may be used for a trail graph, and why not when it
    /// may not.
    ///
    /// Injected rather than reached for, so a suite exercising gap recovery
    /// isn't deciding against the host app's live connection — and so the
    /// composition root stays the only place that knows the answer comes from
    /// ``TileCache``. Defaults to allowing, which is what a provider stub
    /// wants and what a recorder built without an opinion should do.
    @ObservationIgnored let trailGraphNetworkDecision:
        @Sendable (TileFetchPurpose) -> TileNetworkDecision
    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored let sharedStateStore: (any RecordingSharedStateStoring)?
    /// The Lock Screen and Dynamic Island, when the app has one. Optional for
    /// the same reason ``sharedStateStore`` is: a recorder built by a suite
    /// has no business reaching ActivityKit, and one built without an opinion
    /// simply doesn't draw an activity.
    @ObservationIgnored let liveActivityController: HikeLiveActivityController?
    /// Where a finished hike goes if the hiker asked for it in Health, or
    /// `nil` for a launch that must not reach HealthKit — see
    /// ``OpenHikesModel/makeWorkoutWriter()``.
    @ObservationIgnored let workoutWriter: (any HikeWorkoutWriting)?
    /// The order ``workoutWriter`` is asked in, one operation at a time for
    /// each hike, shared with every other path into Health — see
    /// ``HikeWorkoutQueue``.
    @ObservationIgnored let workoutQueue = HikeWorkoutQueue()
    /// What the weather badge holds, read once when a finished hike is
    /// written to Health. A closure rather than the manager, because the
    /// recorder has no other business with the weather and a suite can hand
    /// it a state without building one.
    @ObservationIgnored let weatherState: () -> WeatherBadgeState
    /// The reminders a pause can produce, when the app has any. Optional for
    /// the reason ``liveActivityController`` is: a recorder built by a suite
    /// has no business putting a banner on the developer's Lock Screen, and
    /// one built without an opinion simply never reminds anybody of anything.
    ///
    /// The same instance the walk session holds — see
    /// ``MovementReminderController`` for why a recording and a followed trail
    /// cannot each have their own.
    @ObservationIgnored let movementReminders: MovementReminderController?
    /// What the town a recording started in is called, or `nil` for a launch
    /// that must not ask — see ``RecordingPlaceNaming``, and
    /// ``nameStartPlace(at:)`` for when it is asked.
    @ObservationIgnored let placeNames: (any RecordingPlaceNaming)?
    /// Told the id of every recording once it is saved, which is the walk
    /// session's cue not to start a walk along the line the hiker has just
    /// finished — see ``TrailWalkSession/recordingDidSave(hikeID:)``. A
    /// closure the composition root sets, as the reminders'
    /// `hasActiveRecording` is, because the session is built after this.
    @ObservationIgnored var recordingDidSave: ((UUID) -> Void)?
    @ObservationIgnored let journal: TrackJournal?
    @ObservationIgnored let powerMonitor: PowerStateMonitor
    /// The profile the recorder last asked its source for. Kept here rather
    /// than only in the source so the recording screen can explain the
    /// trade-off it is making without reaching through to CoreLocation.
    /// Written only by ``resolvedEnergyProfile()``, which lives in a different
    /// file and so cannot use `private(set)`.
    var energyProfile: RecordingEnergyProfile = .precise
    @ObservationIgnored let clock: @Sendable () -> Date
    @ObservationIgnored let uptime: @Sendable () -> TimeInterval
    @ObservationIgnored let journalFlushDelay: Duration
    @ObservationIgnored var sessionID: UUID?
    @ObservationIgnored var sessionUptimeBase: TimeInterval?
    @ObservationIgnored var lastAcceptedPoint: RecordingPoint?
    /// The stretch of walk behind ``lastAcceptedPoint``, with its timestamps,
    /// so a photo is placed at its shutter rather than at the Use Photo tap —
    /// see ``RecentRecordingFixes``. Unobserved for the same reason: it is
    /// written on every accepted fix.
    @ObservationIgnored var recentFixes = RecentRecordingFixes()
    /// Whether this pause has reached the point where its sensors were parked
    /// — see ``parkLocationSensors()``, which runs on the journal queue once
    /// the pause is durably written, and ``rearmPausedMovementWatch(at:)``,
    /// which is the launch's version of the same moment.
    ///
    /// Read by ``stopWatchingPausedRecording()``, so that a refusal or a
    /// switch arriving in the milliseconds *before* that is left to the
    /// parking itself: it asks the controller for a fresh answer and will not
    /// start a watch nobody wants. Without this both would park the same
    /// pause, and the second would be telling the location daemon to stop a
    /// feed the first never started.
    @ObservationIgnored var hasParkedPausedSensors = false
    @ObservationIgnored var accumulator = RecordingDistanceAccumulator()
    @ObservationIgnored var elevationFilter = RecordingElevationFilter()
    @ObservationIgnored var latestMotionState: RecordingMotionState = .unknown
    /// Where this recording has stopped, and whether the pause in force is
    /// the app's own — see `HikeRecorder+AutoPause.swift`.
    @ObservationIgnored var autoPause: RecordingAutoPause
    /// Where every delivered fix and change of motion is written down, in a
    /// `DEBUG` build that keeps the evidence Auto-Pause's thresholds are to
    /// be settled by — see ``AutoPauseEvidence``. `nil` everywhere else.
    @ObservationIgnored let autoPauseEvidence: (@Sendable (AutoPauseEvidence.Record) -> Void)?
    @ObservationIgnored var trailGraphPrefetchStates:
        [TrailGraphRegion: TrailGraphPrefetchState] = [:]
    @ObservationIgnored var trailGraphPrefetchTasks:
        [TrailGraphRegion: (id: UUID, task: Task<Void, Never>)] = [:]
    /// The speculative fetch of the regions around the one just loaded. One at
    /// a time, and replaced rather than accumulated: entering a new region is
    /// hours of walking apart, and the neighbours of the region left behind
    /// are no longer the ones worth having.
    @ObservationIgnored var neighborPrefetchTask: Task<Void, Never>?
    /// The live subscription to ``PowerStateMonitor/state``. Held so it can be
    /// cancelled — see ``observePowerState()``.
    @ObservationIgnored var powerStateObservation: Task<Void, Never>?
    @ObservationIgnored var startRequested = false
    /// Whether the failure in ``phase`` is a refused resume's, which left the
    /// walk as paused as it was — see ``refuseResume(_:)``. Cleared by every
    /// ``fail(_:endLocationUpdates:endsActivity:)`` and set after one by the
    /// refusal alone, and read only through ``isResumeRefused``, which asks
    /// the phase too: so it can only ever describe the failure it came with.
    @ObservationIgnored var failureIsRefusedResume = false
    /// The Start currently between asking for a session and having one — see
    /// ``activateSessionIfPossible()``. Cleared by a Discard and by
    /// ``resetSession()``; a failure clears ``startRequested`` instead, which
    /// the activation checks as well. Either way, an activation waking from a
    /// suspension can tell whether it is still the one being waited for.
    @ObservationIgnored var activationID: UUID?
    /// The Resume now being waited on, on the precision sheet or the journal.
    /// What ``activationID`` is to a Start: Stop, Discard and a newer Resume
    /// let go of it, so the one waiting finds, when it wakes, that it is no
    /// longer wanted, and leaves the recorder as they left it (#1608).
    @ObservationIgnored var resumeID: UUID?
    /// Whether a ``discard()`` is under way, from before its first wait to its
    /// end. The phase stays where it was until the end, so a Resume asked for
    /// in those waits would find a walk still paused, and start the GPS for
    /// one about to be thrown away, behind an idle recorder. ``resumeID``
    /// lets go of a Resume already waiting; this refuses one asked for after.
    @ObservationIgnored var isDiscarding = false
    /// What the Start now being waited on begins with, for a recording that
    /// takes over from a hike already under way — see ``RecordingSeed``.
    /// Taken by the activation that makes the session, and let go of by
    /// ``resetSession()``.
    @ObservationIgnored var carriedSeed: RecordingSeed?
    @ObservationIgnored var pendingResumeFlag = false
    /// Refuses live fixes taken before this recording, or its current leg,
    /// began — see ``RecordingFixWindow``. `nil` until a session is under way.
    @ObservationIgnored var fixWindow: RecordingFixWindow?
    @ObservationIgnored var acceptedFixRevision: UInt64 = 0
    @ObservationIgnored var liveMatchWindow: [RecordingPoint] = []
    /// How far this walk has gone along each trail the live matcher could
    /// name — see ``RecordingTrailNames``, and ``suggestedTitle`` for what it
    /// is read for.
    ///
    /// `@ObservationIgnored` like the window it is fed alongside, and for the
    /// same budget: this is written on every accepted fix, and an observed
    /// write at fix rate would invalidate every body that reads the recorder.
    /// Nothing draws it. It is read twice — once when the hiker asks to stop,
    /// and once when the hike is written — both outside a `body`.
    @ObservationIgnored var trailNames = RecordingTrailNames()
    /// The town this walk started in, once the geocoder has answered, and
    /// `nil` before that or when there was no town to give. See
    /// ``nameStartPlace(at:)``, and ``suggestedTitle`` for where it stands in
    /// the walk's name.
    ///
    /// `@ObservationIgnored` for the reason ``trailNames`` is: nothing draws
    /// it, and it is read at Stop and at save, both outside a `body`.
    @ObservationIgnored var startPlaceName: String?
    /// Whether this walk has asked what town it started in, answered or not —
    /// the once in ``nameStartPlace(at:)``.
    @ObservationIgnored var hasAskedForStartPlace = false
    /// The name the stop alert opened with when the hiker stopped, and so the
    /// name the save writes — see ``stop(customName:offeredTitle:)``. `nil`
    /// before Stop, and after a Stop that offered nothing.
    ///
    /// Kept here beside the parts it was made from rather than carried
    /// with the typed name, because it is read where they are: once, in
    /// ``persist(_:prepared:customName:)``, whether the save follows Stop
    /// straight away or a retry.
    @ObservationIgnored var offeredTitle: String?
    /// Whether a tap on Stop is still counting the walk's fixes — see
    /// ``settledStopStep()``. A second tap in that moment is not a second
    /// stop.
    @ObservationIgnored var isSettlingStop = false
    @ObservationIgnored var liveMatchingTask: Task<Void, Never>?
    @ObservationIgnored var liveMatchingTaskID: UUID?
    @ObservationIgnored var liveMatchNeedsRun = false
    @ObservationIgnored var pendingPreparedSave: PendingPreparedSave?
    @ObservationIgnored let journalQueue = SerialAsyncQueue()
    @ObservationIgnored var journalFlushTask: Task<Void, Never>?
    @ObservationIgnored var pendingFixMergeTask: Task<Void, Never>?
    /// The recovery pass ``init`` starts on a launch that recovers
    /// automatically, held rather than fired and forgotten so a caller that
    /// has to switch on ``phase`` can wait for it to settle first. `nil` on a
    /// launch that started none — a suite, or a process with no journal.
    ///
    /// It has to be waited on because `.recovering` is entered
    /// *synchronously*, whether or not there is anything to recover, and is
    /// left only when this task finishes. Anything reading the phase in
    /// between — an App Intent performed on a launch the system made in order
    /// to perform it — sees a recorder that looks busy on a device with no
    /// interrupted hike at all. See ``settleAutomaticRecovery()``.
    @ObservationIgnored private(set) var automaticRecoveryTask: Task<Void, Never>?
    @ObservationIgnored let sharedStateQueue = SerialAsyncQueue()
    @ObservationIgnored var lastSharedSnapshotAt: Date?
    @ObservationIgnored var lastSharedSnapshotPointCount = 0

    static let sharedSnapshotInterval: TimeInterval = 15 * 60
    nonisolated static let liveMatchingMaximumPoints = 20
    nonisolated static let liveMatchingDuration: TimeInterval = 60
    /// How long a stop will wait for the trail-graph regions its gaps need.
    /// Long enough for a handful of Overpass queries on a working connection,
    /// short enough that a hiker who finished in a valley with no signal
    /// still gets their hike saved promptly.
    nonisolated static let gapGraphDownloadBudget: Duration = .seconds(20)

    var isActive: Bool {
        switch phase {
        case .idle: false
        case .recovering: true
        case .waitingForFix, .recording, .paused, .saving, .failed: sessionID != nil || startRequested
        }
    }

    /// Waits out the automatic recovery pass, so ``phase`` answers about the
    /// hiker's hike rather than about the launch.
    ///
    /// Cheap and idempotent: a finished task returns its value immediately,
    /// and a launch that started no pass has nothing to await. Suspending here
    /// releases the main actor, which is what lets the pass — also on the main
    /// actor — run to completion rather than deadlock against this call.
    func settleAutomaticRecovery() async {
        await automaticRecoveryTask?.value
    }

    var canRetrySave: Bool {
        guard case .failed = phase else { return false }
        return pendingPreparedSave != nil
    }

    /// Whether fixes are actually being taken right now, as opposed to a
    /// session that merely exists. A paused or failed session is still
    /// `isActive` — that's how the user gets back to it — but it must not be
    /// described as actively capturing fixes.
    var isCapturingFixes: Bool {
        switch phase {
        case .waitingForFix, .recording: true
        case .idle, .recovering, .paused, .saving, .failed: false
        }
    }

    /// How long this session has been running, from a monotonic source, so an
    /// NTP correction or a manual clock change mid-hike can't make the elapsed
    /// readout jump or run backwards.
    ///
    /// A session recovered from a journal has no in-process baseline — the
    /// uptime it started against belongs to a previous launch — so it falls
    /// back to wall-clock arithmetic, which is the best available answer once
    /// the monotonic origin is gone.
    func elapsedSeconds() -> TimeInterval {
        if let sessionUptimeBase { return max(0, uptime() - sessionUptimeBase) }
        guard let sessionStartedAt else { return 0 }
        return max(0, clock().timeIntervalSince(sessionStartedAt))
    }

    /// Where the journal lives, given what storage this process actually has.
    ///
    /// The widget writes its own pending-fix file rather than touching this
    /// journal, so an unprovisioned App Group must not be the difference
    /// between recording a hike and refusing to. Falls back to Application
    /// Support, the same durable tier ``TileCache`` uses.
    nonisolated static func journalDirectory(
        appGroupContainer: URL?,
        applicationSupport: URL? = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first
    ) -> URL? {
        (appGroupContainer ?? applicationSupport)?
            .appendingPathComponent("Recording", isDirectory: true)
    }

    init(
        container: ModelContainer,
        saveModelContext: @escaping (ModelContext) throws -> Void = { context in
            try context.save()
        },
        photoStore: HikePhotoStore = .shared,
        source: (any RecordingLocationSource)? = nil,
        elevationSource: (any RecordingElevationSource)? = nil,
        motionSource: (any RecordingMotionSource)? = nil,
        trailGraphProvider: (any TrailGraphProviding)? = nil,
        trailGraphRetryPolicy: TrailGraphPrefetchRetryPolicy = .standard,
        trailGraphRetryJitter: @escaping @Sendable () -> Double = {
            Double.random(in: 0...1)
        },
        distanceEvidenceSource: (any RecordingDistanceEvidenceSource)? = nil,
        trailGraphNetworkDecision: (
            @Sendable (TileFetchPurpose) -> TileNetworkDecision
        )? = nil,
        defaults: UserDefaults = .standard,
        powerMonitor: PowerStateMonitor? = nil,
        sharedStateStore: (any RecordingSharedStateStoring)? = nil,
        liveActivityController: HikeLiveActivityController? = nil,
        movementReminders: MovementReminderController? = nil,
        workoutWriter: (any HikeWorkoutWriting)? = nil,
        weatherState: @escaping () -> WeatherBadgeState = { .idle },
        placeNames: (any RecordingPlaceNaming)? = nil,
        journalDirectory: URL? = nil,
        openJournalHandle: @escaping @Sendable (URL) throws -> any TrackJournalHandle = { url in
            try FileHandle(forWritingTo: url)
        },
        clock: @escaping @Sendable () -> Date = { Date() },
        uptime: @escaping @Sendable () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        },
        journalFlushDelay: Duration = .seconds(5),
        autoPausePolicy: AutoPausePolicy = .standard,
        autoPauseEvidence: (@Sendable (AutoPauseEvidence.Record) -> Void)? = nil,
        automaticallyRecovers: Bool = !AppLaunchEnvironment.isRunningTests
    ) {
        let resolvedDirectory = journalDirectory
            ?? Self.journalDirectory(
                appGroupContainer: SharedStore.appGroupContainerURL()
            )
        self.container = container
        self.saveModelContext = saveModelContext
        self.photoStore = photoStore
        self.source = source ?? SystemRecordingLocationSource()
        self.elevationSource = elevationSource
        self.motionSource = motionSource
        self.trailGraphProvider = trailGraphProvider
        self.trailGraphRetryPolicy = trailGraphRetryPolicy
        self.trailGraphRetryJitter = trailGraphRetryJitter
        self.distanceEvidenceSource = distanceEvidenceSource
        self.trailGraphNetworkDecision = trailGraphNetworkDecision
            ?? { _ in .allowed }
        self.defaults = defaults
        self.powerMonitor = powerMonitor ?? PowerStateMonitor()
        self.sharedStateStore = sharedStateStore
        self.liveActivityController = liveActivityController
        self.movementReminders = movementReminders
        self.workoutWriter = workoutWriter
        self.weatherState = weatherState
        self.placeNames = placeNames
        journal = resolvedDirectory.map { directory in
            TrackJournal(directory: directory, clock: clock, openHandle: openJournalHandle)
        }
        self.clock = clock
        self.uptime = uptime
        self.journalFlushDelay = journalFlushDelay
        autoPause = RecordingAutoPause(watch: AutoPauseWatch(policy: autoPausePolicy))
        self.autoPauseEvidence = autoPauseEvidence
        super.init()
        self.source.sourceDelegate = self
        // The controller sees the hiker's switch move; only the recorder can
        // stop the feed a pause started for it. See
        // ``stopWatchingPausedRecording()``.
        movementReminders?.watchingDidEnd = { [weak self] in
            self?.stopWatchingPausedRecording()
        }
        observePowerState()
        if automaticallyRecovers, journal != nil {
            phase = .recovering
            automaticRecoveryTask = Task { [weak self] in
                await self?.recoverOpenSession()
            }
        }
    }
}

// MARK: - Public API

extension HikeRecorder {
    func start() async {
        if case .failed = phase, sessionID == nil {
            resetSession()
        }
        guard phase == .idle else { return }
        startRequested = true
        phase = .waitingForFix
        switch source.authorization {
        case .notDetermined: source.requestWhenInUseAuthorization()
        case .denied: fail(.locationDenied, endLocationUpdates: false)
        case .authorized: await activateSessionIfPossible()
        }
    }

    func pause() {
        // A pause the app made becomes the hiker's, and is no longer ended
        // for them.
        if isAutoPaused {
            takeOverAutoPause()
            return
        }
        guard phase == .waitingForFix || phase == .recording else { return }
        resetAutoPause()
        phase = .paused
        cancelLiveMatching(clearWindow: false)
        publishSharedRecordingSnapshot(force: true)
        journalFlushTask?.cancel()
        journalFlushTask = nil
        let pausedAt = clock()
        hasParkedPausedSensors = false
        // Told before the journal write rather than after it: the prompt this
        // puts up belongs to the tap the hiker has just made, not to a queued
        // write landing after they have left the trailhead. The answer is not
        // carried across that wait — `parkLocationSensors()` asks the
        // controller for a fresh one, which is what lets a refusal answered in
        // those same seconds be heard.
        movementReminders?.recordingDidPause(
            at: lastAcceptedPoint?.coordinate,
            on: pausedAt
        )
        guard let journal else {
            fail(.storageUnavailable)
            return
        }
        journalQueue.enqueue { [weak self] in
            do {
                try await journal.pause(at: pausedAt)
                await self?.parkLocationSensors()
            } catch {
                await self?.fail(.storage(error.localizedDescription))
            }
        }
    }

    /// Reopens the journal and marks the resume in it, answering when the
    /// walk resumed — or `nil` when it did not: the Resume stopped being
    /// wanted across one of the waits, or the journal failed, which fails
    /// the walk.
    private func reopenJournal(resuming attempt: UUID, of session: UUID) async -> Date? {
        do {
            guard let journal else { throw RecordingFailure.storageUnavailable }
            await journalQueue.drain()
            guard isResumeWanted(attempt, of: session) else { return nil }
            try await journal.reopenForAppending()
            guard isResumeWanted(attempt, of: session) else { return nil }
            let resumedAt = clock()
            try await journal.resume(at: resumedAt)
            return isResumeWanted(attempt, of: session) ? resumedAt : nil
        } catch {
            guard isResumeWanted(attempt, of: session) else { return nil }
            fail(error as? RecordingFailure ?? .storage(error.localizedDescription))
            return nil
        }
    }

    /// Whether the Resume `attempt` is still the one wanted, for the session
    /// it was asked about, which is still paused: nothing has stopped,
    /// discarded or resumed it meanwhile, or replaced it with another walk.
    private func isResumeWanted(_ attempt: UUID, of session: UUID) -> Bool {
        resumeID == attempt && sessionID == session && phase == .paused
    }

    func resume() async {
        guard phase == .paused, !isDiscarding, let session = sessionID else { return }
        let attempt = UUID()
        resumeID = attempt
        defer {
            if resumeID == attempt { resumeID = nil }
        }
        // Whoever made the pause, the hiker is ending it: the walk from here
        // is watched for its next stop afresh.
        resetAutoPause()
        // First, before any wait, as `stop()` and `discard()` tell them: the
        // precision sheet and the journal below take as long as they take,
        // and a permission answer landing in them would find the pause still
        // held and post a Resume reminder for a recording being resumed.
        // Every way out from here resumes or fails, and a failure ends the
        // reminders anyway.
        movementReminders?.recordingDidResume()
        guard source.authorization == .authorized else {
            refuseResume(.locationDenied)
            return
        }
        if !source.hasFullAccuracy {
            await source.requestTemporaryFullAccuracy()
            guard isResumeWanted(attempt, of: session) else { return }
        }
        guard source.hasFullAccuracy else {
            refuseResume(.preciseLocationRequired)
            return
        }
        guard let resumedAt = await reopenJournal(resuming: attempt, of: session) else { return }
        // Before any of the recording sensors start: the watch owns the same
        // `CLLocationManager`, and starting a recording feed on top of
        // significant-change monitoring leaves the monitoring behind.
        source.stopMovementWatch()
        let elevationAnchor = lastAcceptedPoint?.elevation
        pendingResumeFlag = true
        // `recentFixes` is kept: the pause is marked on the next fix by the
        // flag above, and a photo taken before it is still placed by the leg
        // it was taken on.
        lastAcceptedPoint = nil
        // With no accepted point to be newer than, the window is all that
        // stands between the new leg and a fix taken while it was paused.
        fixWindow?.reopen(at: resumedAt)
        recoveryState = .absent
        startElevationUpdates(anchorElevation: elevationAnchor)
        startMotionUpdates()
        source.startRecordingUpdates(profile: resolvedEnergyProfile())
        phase = stats.pointCount == 0 ? .waitingForFix : .recording
        publishSharedRecordingSnapshot(force: true)
    }

    /// A resume refused before it changed anything: the walk is as it was,
    /// paused, and only the app can put right what stopped it.
    ///
    /// Failed all the same, so the recording screen says why, and dismissing
    /// that puts the walk back to paused (``dismissFailure()``). But its panel
    /// stays up, paused as it was: a Resume tapped on the Lock Screen is
    /// refused there by the intent that asked, after this returns — see
    /// ``HikeIntentCoordinator/performHikeActivityControl(_:)`` — and a panel
    /// ended here took the reason down with it, leaving the hiker a locked
    /// phone with no walk on it (#1606). Paused is what it says, which a walk
    /// that cannot resume is; nothing publishes to it while the recording is
    /// failed, and the refusal goes with the panel.
    ///
    /// The panel it leaves up still offers Resume and Stop, so both have to
    /// work on it: see ``reopenRefusedResume()``.
    private func refuseResume(_ failure: RecordingFailure) {
        fail(failure, endsActivity: false)
        failureIsRefusedResume = true
    }

    /// Whether the recording has failed only because a resume was refused,
    /// and is still the paused walk it was — see ``refuseResume(_:)``.
    var isResumeRefused: Bool {
        guard case .failed = phase else { return false }
        return failureIsRefusedResume
    }

    /// Puts a walk whose resume was refused back to paused, for a control
    /// that acts on a paused walk, and does nothing to any other.
    ///
    /// For the controls the refusal's panel leaves up. Its Resume, tapped
    /// again, asks Core Location again, rather than finding a failed recording
    /// and saying the hike is no longer being recorded: the hiker may well
    /// have turned Precise Location on in Settings since, and gone straight
    /// back to the Lock Screen. Its Stop opens the app on Stop's question,
    /// which a failed recording would leave unasked. What dismissing the
    /// recording screen's alert does, done for the hiker who asked for
    /// something past it — see ``dismissFailure()``.
    func reopenRefusedResume() {
        guard isResumeRefused else { return }
        dismissFailure()
    }

    /// Ends the walk and saves it, with the stretches trail matching left a
    /// question on kept for *Edit Route* — see ``RouteAssembly``.
    ///
    /// - Parameters:
    ///   - customName: The name the hiker typed, if any. A name field left as
    ///     it opened is not one — see ``RecordingStopName``.
    ///   - offeredTitle: The name the stop alert opened with, which the hike
    ///     is then saved under, beneath any name the hiker typed instead. A
    ///     name shown is a promise, and asking again at the save would break
    ///     it: the town can answer, and the walk go on, while the alert is
    ///     up. `nil` for a Stop that offered nothing, such as Siri's, which
    ///     leaves the name to the save — see
    ///     ``suggestedTitle(forDistance:shape:startedAt:)``.
    @discardableResult func stop(
        customName: String? = nil,
        offeredTitle: String? = nil
    ) async throws -> Hike {
        guard isStoppable else { throw RecordingFailure.save(String(
            localized: "No active recording is ready to stop."
        )) }
        self.offeredTitle = HikeTitle.bounded(offeredTitle)
        // A Resume waiting is no longer wanted, and the phase below says so
        // too, before any wait.
        resumeID = nil
        guard let journal, sessionStartedAt != nil else {
            let failure = RecordingFailure.storageUnavailable
            fail(failure)
            throw failure
        }
        phase = .saving
        resetAutoPause()
        // Told here, before any wait, as `discard()` tells them: a permission
        // answer landing in the merge, the drain or the finish below would
        // otherwise find the pause still held, and post a Resume reminder that
        // the end of the recording takes straight back down. The sensors are
        // released after the waits, and that tells the reminders again, which
        // changes nothing.
        movementReminders?.recordingDidEnd()
        cancelLiveMatching(clearWindow: false)
        cancelTrailGraphPrefetches()
        journalFlushTask?.cancel()
        journalFlushTask = nil
        publishSharedRecordingSnapshot(force: true)
        await pendingFixMergeTask?.value
        pendingFixMergeTask = nil
        // The figures a stop's first minutes are taken back out of: the
        // Health export and the Lock Screen's last panel read them.
        await autoPause.refresh?.value
        autoPause.refresh = nil
        if let sessionID {
            await mergePendingWidgetFixes(for: sessionID)
        }
        await journalQueue.drain()
        let endedAt = clock()
        let session: TrackJournalSession
        do {
            try await journal.finish(at: endedAt)
            guard let loaded = try await journal.loadSession() else { throw RecordingFailure.storageUnavailable }
            session = loaded
            stopLocationSensors()
        } catch let failure as RecordingFailure {
            fail(failure)
            throw failure
        } catch {
            let failure = RecordingFailure.storage(error.localizedDescription)
            fail(failure)
            throw failure
        }
        do {
            return try await finishPreparedSession(
                session,
                journal: journal,
                customName: Self.normalizedCustomName(customName)
            )
        } catch {
            fail(error, endLocationUpdates: false)
            throw error
        }
    }

    func discard() async {
        // First, and before any wait: a Start still waiting on the precision
        // sheet or on its journal must find, when it wakes, that it is no
        // longer wanted — even while this discard is itself still waiting.
        // The request goes too, not only the activation: clearing the one
        // without the other would let the authorization callback — which the
        // precision answer itself fires — begin a fresh activation inside
        // those waits, and one that finished before `resetSession()` would
        // record on behind an idle recorder. A Resume waiting is let go of
        // for the same reason, and one asked for in the waits is refused
        // (`isDiscarding`): the phase stays paused until the end.
        activationID = nil
        resumeID = nil
        isDiscarding = true
        defer { isDiscarding = false }
        startRequested = false
        resetAutoPause()
        cancelLiveMatching(clearWindow: true)
        cancelTrailGraphPrefetches()
        stopLocationSensors()
        journalFlushTask?.cancel()
        journalFlushTask = nil
        await pendingFixMergeTask?.value
        pendingFixMergeTask = nil
        await journalQueue.drain()
        guard let journal else {
            fail(.storageUnavailable, endLocationUpdates: false)
            return
        }
        do {
            try await journal.discard()
            try deleteRecordingHike(sessionID: sessionID)
            endRecordingActivity(.abandoned)
            await clearSharedRecordingState(sessionID: sessionID)
            resetSession()
        } catch let failure as RecordingFailure {
            fail(failure, endLocationUpdates: false)
        } catch {
            fail(.storage(error.localizedDescription), endLocationUpdates: false)
        }
    }

    func sceneWillResignActive() {
        guard isActive else { return }
        publishSharedRecordingSnapshot(force: true)
        journalFlushTask?.cancel()
        journalFlushTask = nil
        enqueueJournalOperation { journal in
            try await journal.flush()
        }
    }

    func sceneDidBecomeActive() {
        guard isActive else { return }
        schedulePendingWidgetFixMerge()
        publishSharedRecordingSnapshot(force: true)
    }

    func dismissFailure() {
        guard case .failed = phase else { return }
        guard !canRetrySave else { return }
        // Past that guard there is no prepared save to retry, so the session
        // goes back to being merely paused.
        if sessionID == nil {
            resetSession()
        } else {
            phase = .paused
        }
    }

    func dismissRecoveryNotice() {
        if recoveryState == .resumed {
            recoveryState = .absent
        }
    }
}
