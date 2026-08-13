//
//  HikeRecorder.swift
//  OpenTrails
//
//  App-scoped live recording coordinator. The view may come and go; this
//  object owns Core Location delivery, the crash-safe journal, and the
//  persisted draft Hike that is finalized in place at Stop.
//

import CoreLocation
import Foundation
import Observation
import OpenTrailsShared
import os
import SwiftData

@Observable
final class HikeRecorder: NSObject {
    nonisolated static let logger = Logger(
        subsystem: "OpenTrails",
        category: "HikeRecorder"
    )

    enum Phase: Equatable {
        case idle
        case recovering
        case waitingForFix
        case recording
        case paused
        case saving
        case reviewing
        case failed(RecordingFailure)
    }

    enum RecoveryState: Equatable {
        case absent
        case resumed
        case needsDecision(RecordingRecoverySummary)
    }

    nonisolated deinit { /* intentionally ignored */ }

    var phase: Phase = .idle
    var recoveryState: RecoveryState = .absent
    var sessionStartedAt: Date?
    var currentHike: Hike?
    var routeReview: RecordingRouteReview?

    let stats = RecordingStats()
    let trace = RecordingTrace()

    @ObservationIgnored let container: ModelContainer
    @ObservationIgnored let source: any RecordingLocationSource
    @ObservationIgnored let elevationSource: (any RecordingElevationSource)?
    @ObservationIgnored let motionSource: (any RecordingMotionSource)?
    @ObservationIgnored let trailGraphProvider: (any TrailGraphProviding)?
    @ObservationIgnored let distanceEvidenceSource: (any RecordingDistanceEvidenceSource)?
    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored let sharedStateStore: (any RecordingSharedStateStoring)?
    @ObservationIgnored let journal: TrackJournal?
    @ObservationIgnored let clock: @Sendable () -> Date
    @ObservationIgnored let uptime: @Sendable () -> TimeInterval
    @ObservationIgnored let journalFlushDelay: Duration
    @ObservationIgnored var sessionID: UUID?
    @ObservationIgnored var sessionUptimeBase: TimeInterval?
    @ObservationIgnored var lastAcceptedPoint: RecordingPoint?
    @ObservationIgnored var accumulator = RecordingDistanceAccumulator()
    @ObservationIgnored var elevationFilter = RecordingElevationFilter()
    @ObservationIgnored var latestMotionState: RecordingMotionState = .unknown
    @ObservationIgnored var requestedGraphRegions: Set<TrailGraphRegion> = []
    @ObservationIgnored var startRequested = false
    @ObservationIgnored var isActivating = false
    @ObservationIgnored var pendingResumeFlag = false
    @ObservationIgnored var acceptedFixRevision: UInt64 = 0
    @ObservationIgnored var liveMatchWindow: [RecordingPoint] = []
    @ObservationIgnored var liveMatchingTask: Task<Void, Never>?
    @ObservationIgnored var liveMatchingTaskID: UUID?
    @ObservationIgnored var liveMatchNeedsRun = false
    @ObservationIgnored var pendingReviewSave: PendingReviewSave?
    @ObservationIgnored let journalQueue = SerialAsyncQueue()
    @ObservationIgnored var journalFlushTask: Task<Void, Never>?
    @ObservationIgnored var pendingFixMergeTask: Task<Void, Never>?
    @ObservationIgnored let sharedStateQueue = SerialAsyncQueue()
    @ObservationIgnored var lastSharedSnapshotAt: Date?
    @ObservationIgnored var lastSharedSnapshotPointCount = 0

    static let sharedSnapshotInterval: TimeInterval = 15 * 60
    nonisolated static let liveMatchingMaximumPoints = 20
    nonisolated static let liveMatchingDuration: TimeInterval = 60

    var isActive: Bool {
        switch phase {
        case .idle: false
        case .recovering: true
        case .waitingForFix, .recording, .paused, .saving, .reviewing, .failed: sessionID != nil || startRequested
        }
    }

    /// Whether fixes are actually being taken right now, as opposed to a
    /// session that merely exists. A paused or failed session is still
    /// `isActive` — that's how the user gets back to it — but it must not be
    /// described as actively capturing fixes.
    var isCapturingFixes: Bool {
        switch phase {
        case .waitingForFix, .recording:
            true

        case .idle, .recovering, .paused, .saving, .reviewing, .failed:
            false
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
        source: (any RecordingLocationSource)? = nil,
        elevationSource: (any RecordingElevationSource)? = nil,
        motionSource: (any RecordingMotionSource)? = nil,
        trailGraphProvider: (any TrailGraphProviding)? = nil,
        distanceEvidenceSource: (any RecordingDistanceEvidenceSource)? = nil,
        defaults: UserDefaults = .standard,
        sharedStateStore: (any RecordingSharedStateStoring)? = nil,
        journalDirectory: URL? = nil,
        clock: @escaping @Sendable () -> Date = { Date() },
        uptime: @escaping @Sendable () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        },
        journalFlushDelay: Duration = .seconds(5),
        automaticallyRecovers: Bool = !AppLaunchEnvironment.isRunningTests
    ) {
        let resolvedDirectory = journalDirectory
            ?? Self.journalDirectory(
                appGroupContainer: SharedStore.appGroupContainerURL()
            )
        self.container = container
        self.source = source ?? SystemRecordingLocationSource()
        self.elevationSource = elevationSource
        self.motionSource = motionSource
        self.trailGraphProvider = trailGraphProvider
        self.distanceEvidenceSource = distanceEvidenceSource
        self.defaults = defaults
        self.sharedStateStore = sharedStateStore
        journal = resolvedDirectory.map { directory in
            TrackJournal(directory: directory, clock: clock)
        }
        self.clock = clock
        self.uptime = uptime
        self.journalFlushDelay = journalFlushDelay
        super.init()
        self.source.sourceDelegate = self
        if automaticallyRecovers, journal != nil {
            phase = .recovering
            Task { [weak self] in
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
        case .notDetermined:
            source.requestWhenInUseAuthorization()

        case .denied:
            fail(.locationDenied, endLocationUpdates: false)

        case .authorized:
            await activateSessionIfPossible()
        }
    }

    func pause() {
        guard phase == .waitingForFix || phase == .recording else { return }
        phase = .paused
        cancelLiveMatching(clearWindow: false)
        publishSharedRecordingSnapshot(force: true)
        journalFlushTask?.cancel()
        journalFlushTask = nil
        let pausedAt = clock()
        guard let journal else {
            fail(.storageUnavailable)
            return
        }
        journalQueue.enqueue { [weak self] in
            do {
                try await journal.pause(at: pausedAt)
                await self?.stopLocationSensors()
            } catch {
                await self?.fail(.storage(error.localizedDescription))
            }
        }
    }

    func resume() async {
        guard phase == .paused else { return }
        guard source.authorization == .authorized else {
            fail(.locationDenied)
            return
        }
        if !source.hasFullAccuracy {
            await source.requestTemporaryFullAccuracy()
        }
        guard source.hasFullAccuracy else {
            fail(.preciseLocationRequired)
            return
        }
        do {
            guard let journal else {
                throw RecordingFailure.storageUnavailable
            }
            await journalQueue.drain()
            try await journal.reopenForAppending()
            try await journal.resume(at: clock())
        } catch let failure as RecordingFailure {
            fail(failure)
            return
        } catch {
            fail(.storage(error.localizedDescription))
            return
        }
        let elevationAnchor = lastAcceptedPoint?.elevation
        pendingResumeFlag = true
        lastAcceptedPoint = nil
        recoveryState = .absent
        startElevationUpdates(anchorElevation: elevationAnchor)
        startMotionUpdates()
        source.startRecordingUpdates()
        phase = stats.pointCount == 0 ? .waitingForFix : .recording
        publishSharedRecordingSnapshot(force: true)
    }

    @discardableResult func stop() async throws -> RecordingStopOutcome {
        guard phase == .waitingForFix
            || phase == .recording
            || phase == .paused else {
            throw RecordingFailure.save("No active recording is ready to stop.")
        }
        guard let journal, sessionStartedAt != nil else {
            let failure = RecordingFailure.storageUnavailable
            fail(failure)
            throw failure
        }
        phase = .saving
        cancelLiveMatching(clearWindow: false)
        journalFlushTask?.cancel()
        journalFlushTask = nil
        publishSharedRecordingSnapshot(force: true)
        await pendingFixMergeTask?.value
        pendingFixMergeTask = nil
        if let sessionID {
            await mergePendingWidgetFixes(for: sessionID)
        }
        await journalQueue.drain()
        let endedAt = clock()
        let session: TrackJournalSession
        do {
            try await journal.finish(at: endedAt)
            guard let loaded = try await journal.loadSession() else {
                throw RecordingFailure.storageUnavailable
            }
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
        do { return try await finishPreparedSession(session, journal: journal) } catch {
            fail(error, endLocationUpdates: false)
            throw error
        }
    }

    func discard() async {
        cancelLiveMatching(clearWindow: true)
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
        if sessionID == nil {
            resetSession()
        } else if pendingReviewSave != nil {
            phase = .reviewing
        } else {
            phase = .paused
        }
    }

    func dismissRecoveryNotice() {
        if recoveryState == .resumed {
            recoveryState = .absent
        }
    }

    func selectRouteChoice(_ choice: TrailRouteChoice) {
        guard phase == .reviewing, let routeReview else { return }
        routeReview.select(choice)
        updateReviewPreview()
    }

    func moveToPreviousReviewSection() {
        guard phase == .reviewing, let routeReview else { return }
        routeReview.moveBackward()
        updateReviewPreview()
    }

    func moveToNextReviewSection() {
        guard phase == .reviewing, let routeReview else { return }
        routeReview.moveForward()
        updateReviewPreview()
    }

    func saveReviewedRecording() async throws -> Hike {
        guard phase == .reviewing,
              let pendingReviewSave,
              let routeReview,
              let journal else {
            throw RecordingFailure.save("No reviewed recording is ready to save.")
        }
        phase = .saving
        do {
            let points = pendingReviewSave.normalizedPoints
            let choices = routeReview.legChoices
            let startedAt = pendingReviewSave.session.metadata.startedAt
            let endedAt = try {
                guard let endedAt = pendingReviewSave.session.metadata.endedAt else {
                    throw RecordingFailure.save("The recording has not been finished yet.")
                }
                return endedAt
            }()
            let prepared = try await Task.detached(priority: .userInitiated) {
                assertOffMainThread("Route review resolution must stay off the main thread")
                return try RecordingPreparation.prepareResolved(
                    points: points,
                    startedAt: startedAt,
                    endedAt: endedAt,
                    matchResult: pendingReviewSave.matchResult,
                    choices: choices
                )
            }.value
            let hike = try persist(pendingReviewSave.session, prepared: prepared)
            await finishSavedSession(pendingReviewSave.session, journal: journal)
            return hike
        } catch let failure as RecordingFailure {
            fail(failure, endLocationUpdates: false)
            throw failure
        } catch {
            let failure = RecordingFailure.save(error.localizedDescription)
            fail(failure, endLocationUpdates: false)
            throw failure
        }
    }
}
