//
//  HikeRecorder.swift
//  OpenTrails
//
//  App-scoped live recording coordinator. The view may come and go; this
//  object owns Core Location delivery and the crash-safe journal until Stop.
//

import CoreLocation
import Foundation
import Observation
import OpenTrailsShared
import os
import SwiftData

nonisolated enum RecordingFailure: LocalizedError, Equatable, Sendable {
    case locationDenied
    case preciseLocationRequired
    case storageUnavailable
    case storage(String)
    case tooShort
    case save(String)

    var errorDescription: String? {
        switch self {
        case .locationDenied:
            "Location access is needed to record a hike."
        case .preciseLocationRequired:
            "Precise Location is needed to record a hike."
        case .storageUnavailable:
            "The recording journal couldn’t be created."
        case .storage:
            "The recording could not be written safely."
        case .tooShort:
            "This recording has only one track point."
        case .save:
            "The recorded hike couldn’t be saved."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .locationDenied:
            "Allow location access in Settings, then try again."
        case .preciseLocationRequired:
            "Turn on Precise Location for OpenTrails in Settings."
        case .storageUnavailable:
            "Check that the app has storage available, then try again."
        case .storage(let detail), .save(let detail):
            detail
        case .tooShort:
            "A hike needs at least two points to have a route."
        }
    }
}

@MainActor
enum RecordingLocationAuthorization: Equatable {
    case notDetermined
    case authorized
    case denied
}

@MainActor
protocol RecordingLocationSource: AnyObject {
    var authorization: RecordingLocationAuthorization { get }
    var hasFullAccuracy: Bool { get }
    var sourceDelegate: CLLocationManagerDelegate? { get set }

    func requestWhenInUseAuthorization()
    func requestTemporaryFullAccuracy() async
    func startRecordingUpdates(profile: RecordingAccuracyProfile)
    func stopRecordingUpdates()
}

@MainActor
final class SystemRecordingLocationSource: RecordingLocationSource {
    private let manager = CLLocationManager()

    var authorization: RecordingLocationAuthorization {
        switch manager.authorizationStatus {
        case .notDetermined:
            .notDetermined
        case .authorizedAlways, .authorizedWhenInUse:
            .authorized
        case .denied, .restricted:
            .denied
        @unknown default:
            .denied
        }
    }

    var hasFullAccuracy: Bool {
        #if os(iOS)
        manager.accuracyAuthorization == .fullAccuracy
        #else
        true
        #endif
    }

    var sourceDelegate: CLLocationManagerDelegate? {
        get { manager.delegate }
        set { manager.delegate = newValue }
    }

    func requestWhenInUseAuthorization() {
        manager.requestWhenInUseAuthorization()
    }

    func requestTemporaryFullAccuracy() async {
        #if os(iOS)
        guard manager.accuracyAuthorization == .reducedAccuracy else { return }
        await withCheckedContinuation { continuation in
            manager.requestTemporaryFullAccuracyAuthorization(
                withPurposeKey: "RecordHike"
            ) { _ in
                continuation.resume()
            }
        }
        #endif
    }

    func startRecordingUpdates(profile: RecordingAccuracyProfile) {
        manager.activityType = .fitness
        manager.pausesLocationUpdatesAutomatically = false
        #if os(iOS)
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        #endif

        switch profile {
        case .high:
            manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
            manager.distanceFilter = kCLDistanceFilterNone
            manager.startUpdatingLocation()
        case .balanced:
            manager.desiredAccuracy = kCLLocationAccuracyBest
            manager.distanceFilter = 10
            manager.startUpdatingLocation()
        case .batterySaver:
            manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
            manager.distanceFilter = 100
            manager.startMonitoringSignificantLocationChanges()
        }
    }

    func stopRecordingUpdates() {
        manager.stopUpdatingLocation()
        manager.stopMonitoringSignificantLocationChanges()
        #if os(iOS)
        manager.allowsBackgroundLocationUpdates = false
        manager.showsBackgroundLocationIndicator = false
        #endif
    }
}

nonisolated struct RecordingRecoverySummary: Equatable, Sendable {
    let startedAt: Date
    let lastUpdatedAt: Date
    let distanceMeters: Double
    let pointCount: Int
}

@MainActor
@Observable
final class HikeRecorder: NSObject {
    private static let logger = Logger(
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
        case failed(RecordingFailure)
    }

    enum RecoveryState: Equatable {
        case none
        case resumed
        case needsDecision(RecordingRecoverySummary)
    }

    nonisolated deinit {}

    private(set) var phase: Phase = .idle
    private(set) var recoveryState: RecoveryState = .none
    private(set) var sessionStartedAt: Date?

    let stats = RecordingStats()
    let trace = RecordingTrace()

    @ObservationIgnored private let container: ModelContainer
    @ObservationIgnored private let source: any RecordingLocationSource
    @ObservationIgnored private let elevationSource:
        (any RecordingElevationSource)?
    @ObservationIgnored private let trailGraphProvider:
        (any TrailGraphProviding)?
    @ObservationIgnored private let distanceEvidenceSource:
        (any RecordingDistanceEvidenceSource)?
    @ObservationIgnored private let onlineMatcher:
        (any RecordingOnlineMatching)?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let onlineMatchingAvailable:
        @Sendable () -> Bool
    @ObservationIgnored private let sharedStateStore:
        (any RecordingSharedStateStoring)?
    @ObservationIgnored private let journal: TrackJournal?
    @ObservationIgnored private let clock: @Sendable () -> Date
    @ObservationIgnored private let uptime: @Sendable () -> TimeInterval
    @ObservationIgnored private let journalFlushDelay: Duration
    @ObservationIgnored private var sessionID: UUID?
    @ObservationIgnored private var sessionOptions:
        RecordingSessionOptions?
    @ObservationIgnored private var sessionUptimeBase: TimeInterval?
    @ObservationIgnored private var lastAcceptedPoint: RecordingPoint?
    @ObservationIgnored private var accumulator = RecordingDistanceAccumulator()
    @ObservationIgnored private var elevationFilter = RecordingElevationFilter()
    @ObservationIgnored private var lastGraphPrefetchCoordinate:
        CLLocationCoordinate2D?
    @ObservationIgnored private var startRequested = false
    @ObservationIgnored private var isActivating = false
    @ObservationIgnored private var pendingResumeFlag = false
    @ObservationIgnored private var acceptedFixRevision: UInt64 = 0
    @ObservationIgnored private var journalTail: Task<Void, Never>?
    @ObservationIgnored private var journalFlushTask: Task<Void, Never>?
    @ObservationIgnored private var pendingFixMergeTask: Task<Void, Never>?
    @ObservationIgnored private var sharedStateTail: Task<Void, Never>?
    @ObservationIgnored private var lastSharedSnapshotAt: Date?
    @ObservationIgnored private var lastSharedSnapshotPointCount = 0

    private static let sharedSnapshotInterval: TimeInterval = 15 * 60

    var isActive: Bool {
        switch phase {
        case .idle:
            false
        case .recovering:
            true
        case .waitingForFix, .recording, .paused, .saving, .failed:
            sessionID != nil || startRequested
        }
    }

    /// Whether fixes are actually being taken right now, as opposed to a
    /// session that merely exists. The hikes-list pill reads this: a paused or
    /// failed session is still `isActive` — that's how the user gets back to
    /// it — but describing it as "recording" while its timer ticks upward is a
    /// lie the walker only discovers afterwards.
    var isCapturingFixes: Bool {
        switch phase {
        case .waitingForFix, .recording:
            true
        case .idle, .recovering, .paused, .saving, .failed:
            false
        }
    }

    /// How long this session has been running, from a monotonic source, so an
    /// NTP correction or a manual clock change mid-hike can't make the elapsed
    /// readout jump or run backwards (`RECORD_HIKE.md` §13).
    ///
    /// A session recovered from a journal has no in-process baseline — the
    /// uptime it started against belongs to a previous launch — so it falls
    /// back to wall-clock arithmetic, which is the best available answer once
    /// the monotonic origin is gone.
    func elapsedSeconds() -> TimeInterval {
        if let sessionUptimeBase {
            return max(0, uptime() - sessionUptimeBase)
        }
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
        trailGraphProvider: (any TrailGraphProviding)? = nil,
        distanceEvidenceSource:
            (any RecordingDistanceEvidenceSource)? = nil,
        onlineMatcher: (any RecordingOnlineMatching)? = nil,
        defaults: UserDefaults = .standard,
        onlineMatchingAvailable: @escaping @Sendable () -> Bool = {
            Secrets.apiKey(for: .stadiaOutdoors) != nil
        },
        sharedStateStore: (any RecordingSharedStateStoring)? = nil,
        journalDirectory: URL? = nil,
        clock: @escaping @Sendable () -> Date = { Date() },
        uptime: @escaping @Sendable () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        },
        journalFlushDelay: Duration = .seconds(5),
        automaticallyRecovers: Bool = !AppLaunchEnvironment.isHostingTests
    ) {
        let resolvedDirectory = journalDirectory
            ?? Self.journalDirectory(
                appGroupContainer: SharedStore.appGroupContainerURL()
            )
        self.container = container
        self.source = source ?? SystemRecordingLocationSource()
        self.elevationSource = elevationSource
        self.trailGraphProvider = trailGraphProvider
        self.distanceEvidenceSource = distanceEvidenceSource
        self.onlineMatcher = onlineMatcher
        self.defaults = defaults
        self.onlineMatchingAvailable = onlineMatchingAvailable
        self.sharedStateStore = sharedStateStore
        self.journal = resolvedDirectory.map {
            TrackJournal(directory: $0, clock: clock)
        }
        self.clock = clock
        self.uptime = uptime
        self.journalFlushDelay = journalFlushDelay
        super.init()
        self.source.sourceDelegate = self

        if automaticallyRecovers, self.journal != nil {
            phase = .recovering
            Task { [weak self] in
                await self?.recoverOpenSession()
            }
        }
    }

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
        publishSharedRecordingSnapshot(force: true)
        journalFlushTask?.cancel()
        journalFlushTask = nil
        let pausedAt = clock()
        guard let journal else {
            fail(.storageUnavailable)
            return
        }
        let previous = journalTail
        journalTail = Task { [weak self] in
            await previous?.value
            do {
                try await journal.pause(at: pausedAt)
                self?.source.stopRecordingUpdates()
                self?.elevationSource?.stop()
            } catch {
                self?.fail(.storage(error.localizedDescription))
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
            guard let journal else { throw RecordingFailure.storageUnavailable }
            await journalTail?.value
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
        recoveryState = .none
        startElevationUpdates(
            anchorElevation: elevationAnchor
        )
        source.startRecordingUpdates(
            profile: activeSessionOptions.accuracyProfile
        )
        phase = stats.pointCount == 0 ? .waitingForFix : .recording
        publishSharedRecordingSnapshot(force: true)
    }

    @discardableResult
    func stop() async throws -> Hike {
        guard phase == .waitingForFix
                || phase == .recording
                || phase == .paused else {
            throw RecordingFailure.save(
                "No active recording is ready to stop."
            )
        }
        guard let journal, sessionStartedAt != nil else {
            let failure = RecordingFailure.storageUnavailable
            fail(failure)
            throw failure
        }

        phase = .saving
        journalFlushTask?.cancel()
        journalFlushTask = nil
        publishSharedRecordingSnapshot(force: true)
        await pendingFixMergeTask?.value
        pendingFixMergeTask = nil
        if let sessionID {
            await mergePendingWidgetFixes(for: sessionID)
        }
        await journalTail?.value

        let endedAt = clock()
        let session: TrackJournalSession
        do {
            try await journal.finish(at: endedAt)
            guard let loaded = try await journal.loadSession() else {
                throw RecordingFailure.storageUnavailable
            }
            session = loaded
            source.stopRecordingUpdates()
            elevationSource?.stop()
        } catch let failure as RecordingFailure {
            fail(failure)
            throw failure
        } catch {
            let failure = RecordingFailure.storage(error.localizedDescription)
            fail(failure)
            throw failure
        }

        let hike: Hike
        do {
            hike = try await persist(session)
        } catch {
            fail(error, endLocationUpdates: false)
            throw error
        }

        await clearSharedRecordingState(sessionID: session.metadata.sessionID)
        do {
            try await journal.discard()
        } catch {
            Self.logger.error(
                "Saved hike but could not remove its finished journal: \(error.localizedDescription, privacy: .public)"
            )
        }

        resetSession()
        return hike
    }

    func discard() async {
        source.stopRecordingUpdates()
        elevationSource?.stop()
        journalFlushTask?.cancel()
        journalFlushTask = nil
        await pendingFixMergeTask?.value
        pendingFixMergeTask = nil
        await journalTail?.value
        guard let journal else {
            fail(.storageUnavailable, endLocationUpdates: false)
            return
        }
        do {
            try await journal.discard()
            await clearSharedRecordingState(sessionID: sessionID)
            resetSession()
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
        } else {
            phase = .paused
        }
    }

    func dismissRecoveryNotice() {
        if recoveryState == .resumed {
            recoveryState = .none
        }
    }

    func recoverOpenSession(automaticallyResume: Bool = true) async {
        guard phase == .idle || phase == .recovering else { return }
        guard let journal else {
            phase = .idle
            return
        }
        phase = .recovering

        var session: TrackJournalSession
        do {
            guard let loaded = try await journal.loadSession() else {
                await clearSharedRecordingState(sessionID: nil)
                phase = .idle
                return
            }
            session = loaded
        } catch {
            fail(.storage(error.localizedDescription), endLocationUpdates: false)
            return
        }

        sessionID = session.metadata.sessionID
        sessionStartedAt = session.metadata.startedAt
        sessionOptions = session.metadata.recordingOptions ?? .defaults
        let recoveryLastUpdatedAt = session.metadata.lastUpdatedAt
        startRequested = true
        do {
            try await journal.reopenForAppending()
        } catch {
            fail(.storage(error.localizedDescription), endLocationUpdates: false)
            return
        }
        await mergePendingWidgetFixes(for: session.metadata.sessionID)
        if case .failed = phase { return }
        do {
            if let merged = try await journal.loadSession() {
                session = merged
            }
        } catch {
            fail(.storage(error.localizedDescription), endLocationUpdates: false)
            return
        }
        let recoveredPoints = session.points
        session.points = await Task.detached {
            RecordingPreparation.normalizedPoints(recoveredPoints)
        }.value
        lastAcceptedPoint = session.points.last
        rebuildLiveState(from: session.points)
        await finishRecovery(
            session: session,
            journal: journal,
            recoveryLastUpdatedAt: recoveryLastUpdatedAt,
            automaticallyResume: automaticallyResume
        )
    }

    private func finishRecovery(
        session: TrackJournalSession,
        journal: TrackJournal,
        recoveryLastUpdatedAt: Date,
        automaticallyResume: Bool
    ) async {
        if session.metadata.endedAt != nil {
            phase = .saving
            do {
                _ = try await persist(session)
                await clearSharedRecordingState(
                    sessionID: session.metadata.sessionID
                )
                try await journal.discard()
                resetSession()
            } catch let failure as RecordingFailure {
                fail(failure, endLocationUpdates: false)
            } catch {
                fail(.save(error.localizedDescription), endLocationUpdates: false)
            }
            return
        }

        let summary = RecordingRecoverySummary(
            startedAt: session.metadata.startedAt,
            lastUpdatedAt: recoveryLastUpdatedAt,
            distanceMeters: stats.distanceMeters,
            pointCount: stats.pointCount
        )
        let wasPaused = session.metadata.pausedIntervals.last.map {
            $0.endedAt == nil
        } ?? false
        if wasPaused {
            phase = .paused
            recoveryState = .needsDecision(summary)
            publishSharedRecordingSnapshot(force: true)
            return
        }
        let isRecent = clock().timeIntervalSince(recoveryLastUpdatedAt) < 5 * 60
        if automaticallyResume, isRecent,
           source.authorization == .authorized, source.hasFullAccuracy {
            startElevationUpdates(
                anchorElevation: lastAcceptedPoint?.elevation
            )
            source.startRecordingUpdates(
                profile: activeSessionOptions.accuracyProfile
            )
            phase = session.points.isEmpty ? .waitingForFix : .recording
            recoveryState = .resumed
        } else {
            phase = .paused
            recoveryState = .needsDecision(summary)
        }
        publishSharedRecordingSnapshot(force: true)
    }

    private func activateSessionIfPossible() async {
        guard startRequested, sessionID == nil, !isActivating else { return }
        isActivating = true
        defer { isActivating = false }

        if !source.hasFullAccuracy {
            await source.requestTemporaryFullAccuracy()
        }
        guard source.hasFullAccuracy else {
            fail(.preciseLocationRequired, endLocationUpdates: false)
            return
        }
        guard let journal else {
            fail(.storageUnavailable, endLocationUpdates: false)
            return
        }

        let id = UUID()
        let startedAt = clock()
        let options = RecordingSessionOptions.load(
            from: defaults,
            onlineMatchingAvailable:
                onlineMatcher != nil && onlineMatchingAvailable()
        )
        do {
            try await journal.start(
                sessionID: id,
                startedAt: startedAt,
                recordingOptions: options
            )
        } catch {
            fail(.storage(error.localizedDescription), endLocationUpdates: false)
            return
        }

        sessionID = id
        sessionStartedAt = startedAt
        sessionOptions = options
        sessionUptimeBase = uptime()
        stats.reset()
        trace.reset()
        accumulator = RecordingDistanceAccumulator()
        elevationFilter.reset()
        lastAcceptedPoint = nil
        lastGraphPrefetchCoordinate = nil
        pendingResumeFlag = false
        recoveryState = .none
        startElevationUpdates()
        source.startRecordingUpdates(profile: options.accuracyProfile)
        phase = .waitingForFix
        publishSharedRecordingSnapshot(force: true)
    }

    private func accept(_ location: CLLocation) {
        guard phase == .waitingForFix || phase == .recording else { return }
        if LocationFixPolicy.accepts(
            location,
            maximumAge: LocationFixPolicy.foregroundMaximumAge,
            now: clock()
        ) {
            stats.horizontalAccuracy = location.horizontalAccuracy
        }
        guard RecordingFixPolicy.accepts(
                location,
                after: lastAcceptedPoint,
                now: clock()
              ) else {
            return
        }

        var flags: RecordingPointFlags = []
        if pendingResumeFlag {
            flags.insert(.resumed)
            pendingResumeFlag = false
        }
        var point = RecordingPoint(location: location, flags: flags)
        point.elevation = elevationFilter.elevation(for: location)
        let distance = accumulator.append(point)
        if accumulator.isStationary {
            point.flags.insert(.stationary)
        }
        lastAcceptedPoint = point
        acceptedFixRevision &+= 1

        trace.append(point.coordinate)
        stats.distanceMeters = distance
        stats.pointCount += 1
        stats.horizontalAccuracy = point.horizontalAccuracy
        stats.averageSpeedMetersPerSecond = accumulator.averageSpeedMetersPerSecond
        // Explicitly conditional, not `phase = .recording`. `@Observable`'s
        // expansion happens to skip a write that compares equal, so the
        // unconditional form is quiet *today* — but only because `Phase` is
        // `Equatable`. Give one case a non-`Equatable` payload and every body
        // reading `phase` (this view's, and the whole hikes sheet's via
        // `isActive`) silently starts re-rendering at fix rate, which is
        // exactly the budget `RECORD_HIKE.md` §12 sets. Say it out loud.
        if phase != .recording {
            phase = .recording
        }
        RenderSignpost.mark("LiveFixAccepted")
        prefetchTrailGraphIfNeeded(around: point.coordinate)

        let pointToJournal = point
        enqueueJournalOperation { journal in
            try await journal.append(pointToJournal)
        }
        scheduleJournalFlush()
        schedulePendingWidgetFixMerge()
        publishSharedRecordingSnapshot(
            force: stats.pointCount == 1
        )
    }

    private func startElevationUpdates(
        anchorElevation: Double? = nil
    ) {
        elevationSource?.stop()
        elevationFilter.restart(at: anchorElevation)
        guard let elevationSource, elevationSource.isAvailable else { return }
        elevationSource.start { [weak self] relativeAltitude in
            Task { @MainActor [weak self] in
                self?.elevationFilter.update(
                    relativeAltitude: relativeAltitude
                )
            }
        }
    }

    private func prefetchTrailGraphIfNeeded(
        around coordinate: CLLocationCoordinate2D
    ) {
        guard activeSessionOptions.snapToTrails,
              let trailGraphProvider,
              lastGraphPrefetchCoordinate == nil else { return }
        lastGraphPrefetchCoordinate = coordinate
        Task {
            do {
                try await trailGraphProvider.prefetch(around: coordinate)
            } catch {
                Self.logger.error(
                    "Trail graph prefetch failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    private func gapDistances(
        for points: [RecordingPoint]
    ) async -> [Int: Double] {
        guard let distanceEvidenceSource, points.count > 1 else { return [:] }
        var distances: [Int: Double] = [:]
        for index in 1..<points.count
        where TrailMatcher.needsDistanceEvidence(
            from: points[index - 1],
            to: points[index]
        ) {
            if let distance = await distanceEvidenceSource.distance(
                from: points[index - 1].timestamp,
                to: points[index].timestamp
            ), distance.isFinite, distance >= 0 {
                distances[index] = distance
            }
        }
        return distances
    }

    private func enqueueJournalOperation(
        _ operation: @escaping @Sendable (TrackJournal) async throws -> Void
    ) {
        guard let journal else {
            fail(.storageUnavailable)
            return
        }
        let previous = journalTail
        journalTail = Task { [weak self] in
            await previous?.value
            do {
                try await operation(journal)
            } catch {
                self?.fail(.storage(error.localizedDescription))
            }
        }
    }

    private func scheduleJournalFlush() {
        guard journalFlushTask == nil else { return }
        let delay = journalFlushDelay
        journalFlushTask = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.journalFlushTask = nil
            self.enqueueJournalOperation { journal in
                try await journal.flush()
            }
        }
    }

    private var activeSessionOptions: RecordingSessionOptions {
        sessionOptions ?? .defaults
    }

    private func schedulePendingWidgetFixMerge() {
        guard pendingFixMergeTask == nil,
              let sessionID,
              sharedStateStore != nil else {
            return
        }
        pendingFixMergeTask = Task { [weak self] in
            guard let self else { return }
            await self.mergePendingWidgetFixes(for: sessionID)
            self.pendingFixMergeTask = nil
        }
    }

    private func mergePendingWidgetFixes(for expectedSessionID: UUID) async {
        guard sessionID == expectedSessionID,
              let sharedStateStore,
              let journal else {
            return
        }

        let fixes: [SharedRecordingFix]
        do {
            fixes = try await sharedStateStore.pendingFixes(
                for: expectedSessionID
            )
        } catch {
            Self.logger.error(
                "Pending widget fixes could not be read: \(error.localizedDescription, privacy: .public)"
            )
            return
        }
        guard !fixes.isEmpty else { return }

        let mergeRevision: UInt64
        while true {
            let revision = acceptedFixRevision
            let tail = journalTail
            await tail?.value
            guard sessionID == expectedSessionID else { return }
            if case .failed = phase { return }
            if acceptedFixRevision == revision {
                mergeRevision = revision
                break
            }
        }
        let mergedCount: Int
        do {
            mergedCount = try await journal.mergeWidgetFixes(
                fixes.map(RecordingPoint.init(sharedFix:))
            )
        } catch {
            fail(.storage(error.localizedDescription))
            return
        }

        do {
            try await sharedStateStore.removePendingFixes(
                ids: Set(fixes.map(\.id))
            )
        } catch {
            // The journal merge is already durable. Leaving the shared copies
            // behind is safe because the next merge deduplicates by timestamp.
            Self.logger.error(
                "Merged widget fixes could not be cleared: \(error.localizedDescription, privacy: .public)"
            )
        }

        guard mergedCount > 0 else { return }
        await refreshLiveStateAfterJournalMerge(
            expectedSessionID: expectedSessionID,
            journal: journal,
            minimumRevision: mergeRevision
        )
    }

    private func refreshLiveStateAfterJournalMerge(
        expectedSessionID: UUID,
        journal: TrackJournal,
        minimumRevision: UInt64
    ) async {
        while sessionID == expectedSessionID,
              acceptedFixRevision >= minimumRevision {
            let revision = acceptedFixRevision
            let tail = journalTail
            await tail?.value
            guard sessionID == expectedSessionID else { return }
            if case .failed = phase { return }

            do {
                guard let mergedSession = try await journal.loadSession() else {
                    return
                }
                let points = mergedSession.points
                let normalized = await Task.detached {
                    RecordingPreparation.normalizedPoints(points)
                }.value
                guard acceptedFixRevision == revision,
                      sessionID == expectedSessionID else {
                    continue
                }
                lastAcceptedPoint = normalized.last
                rebuildLiveState(from: normalized)
                publishSharedRecordingSnapshot(force: true)
                return
            } catch {
                fail(.storage(error.localizedDescription))
                return
            }
        }
    }

    private func publishSharedRecordingSnapshot(force: Bool) {
        guard sharedStateStore != nil,
              let sessionID,
              let sessionStartedAt else {
            return
        }
        let now = clock()
        let firstPoint = stats.pointCount == 1
            && lastSharedSnapshotPointCount == 0
        let intervalElapsed = lastSharedSnapshotAt.map {
            now.timeIntervalSince($0) >= Self.sharedSnapshotInterval
        } ?? true
        guard force || firstPoint || intervalElapsed else { return }

        let snapshot = SharedRecordingSnapshot(
            sessionID: sessionID,
            startedAt: sessionStartedAt,
            distanceMeters: stats.distanceMeters,
            pointCount: stats.pointCount,
            polyline: trace.widgetPolyline(),
            isCapturingFixes: isCapturingFixes,
            updatedAt: now
        )
        lastSharedSnapshotAt = now
        lastSharedSnapshotPointCount = stats.pointCount
        let reloadWidget = force || firstPoint
        enqueueSharedStateOperation { store in
            try await store.save(
                snapshot,
                reloadWidget: reloadWidget
            )
        }
    }

    private func enqueueSharedStateOperation(
        _ operation: @escaping @Sendable (
            any RecordingSharedStateStoring
        ) async throws -> Void
    ) {
        guard let sharedStateStore else { return }
        let previous = sharedStateTail
        sharedStateTail = Task {
            await previous?.value
            do {
                try await operation(sharedStateStore)
            } catch {
                Self.logger.error(
                    "Recording widget state update failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    private func clearSharedRecordingState(sessionID: UUID?) async {
        guard let sharedStateStore else { return }
        await sharedStateTail?.value
        do {
            try await sharedStateStore.clear(sessionID: sessionID)
        } catch {
            Self.logger.error(
                "Recording widget state could not be cleared: \(error.localizedDescription, privacy: .public)"
            )
        }
        sharedStateTail = nil
        lastSharedSnapshotAt = nil
        lastSharedSnapshotPointCount = 0
    }

    private func rebuildLiveState(from points: [RecordingPoint]) {
        accumulator = RecordingDistanceAccumulator()
        for point in points {
            accumulator.append(point)
        }
        stats.distanceMeters = accumulator.distanceMeters
        stats.pointCount = points.count
        stats.horizontalAccuracy = points.last?.horizontalAccuracy
        stats.averageSpeedMetersPerSecond = accumulator.averageSpeedMetersPerSecond
        trace.replace(with: points.map(\.coordinate))
    }

    private func persist(
        _ session: TrackJournalSession
    ) async throws(RecordingFailure) -> Hike {
        let sessionID = session.metadata.sessionID
        let descriptor = FetchDescriptor<Hike>(
            predicate: #Predicate { $0.id == sessionID }
        )
        do {
            if let existing = try container.mainContext.fetch(descriptor).first {
                return existing
            }
        } catch {
            throw .save(error.localizedDescription)
        }

        guard let endedAt = session.metadata.endedAt else {
            throw .save("The recording has not been finished yet.")
        }

        var prepared: PreparedRecording
        do {
            let options = session.metadata.recordingOptions
                ?? activeSessionOptions
            let normalized = await Task.detached(
                priority: .userInitiated
            ) {
                assertOffMainThread(
                    "Recording normalization must stay off the main thread"
                )
                return RecordingPreparation.normalizedPoints(session.points)
            }.value
            let graph: TrailGraph?
            if options.snapToTrails,
               let trailGraphProvider {
                do {
                    graph = try await trailGraphProvider.cachedGraph(
                        covering: normalized.map(\.coordinate)
                    )
                } catch {
                    Self.logger.error(
                        "Cached trail graph could not be loaded: \(error.localizedDescription, privacy: .public)"
                    )
                    graph = nil
                }
            } else {
                graph = nil
            }
            let gapDistances = await gapDistances(for: normalized)
            prepared = try await Task.detached(priority: .userInitiated) {
                assertOffMainThread("Recording preparation must stay off the main thread")
                return try RecordingPreparation.prepare(
                    points: normalized,
                    startedAt: session.metadata.startedAt,
                    endedAt: endedAt,
                    graph: graph,
                    gapDistances: gapDistances,
                    keepRawGPSTrack: options.keepRawGPSTrack
                )
            }.value

            if options.snapToTrails,
               options.improveAccuracyOnline,
               !normalized.contains(where: {
                   $0.flags.contains(.resumed)
               }),
               let onlineMatcher {
                do {
                    let onlineRoute = try await onlineMatcher.match(
                        points: normalized
                    )
                    prepared = PreparedRecording(
                        route: onlineRoute,
                        rawRoute: options.keepRawGPSTrack
                            ? normalized.map(\.routeCoordinate)
                            : [],
                        distanceMeters: Self.routeDistance(onlineRoute),
                        startedAt: prepared.startedAt,
                        endedAt: prepared.endedAt,
                        matchedTrailName: prepared.matchedTrailName,
                        ambiguousLegCount: 0
                    )
                } catch {
                    Self.logger.error(
                        "Online recording match failed; keeping the on-device result: \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
        } catch let failure as RecordingFailure {
            throw failure
        } catch {
            throw .save(error.localizedDescription)
        }

        if prepared.ambiguousLegCount > 0 {
            Self.logger.info(
                "Kept \(prepared.ambiguousLegCount) ambiguous trail legs on raw GPS geometry"
            )
        }
        stats.matchedTrailName = prepared.matchedTrailName
        let hike = Hike(
            id: sessionID,
            title: session.metadata.title ?? Self.defaultTitle(for: prepared.startedAt),
            distanceMeters: prepared.distanceMeters,
            date: prepared.startedAt,
            tintHex: Hike.randomTintHex(),
            route: prepared.route,
            rawRoute: prepared.rawRoute
        )
        container.mainContext.insert(hike)
        do {
            try container.mainContext.save()
            return hike
        } catch {
            container.mainContext.delete(hike)
            throw .save(error.localizedDescription)
        }
    }

    private func fail(
        _ failure: RecordingFailure,
        endLocationUpdates: Bool = true
    ) {
        if endLocationUpdates {
            source.stopRecordingUpdates()
            elevationSource?.stop()
        }
        journalFlushTask?.cancel()
        journalFlushTask = nil
        phase = .failed(failure)
        startRequested = false
        if sessionID != nil {
            publishSharedRecordingSnapshot(force: true)
        }
    }

    private func resetSession() {
        phase = .idle
        recoveryState = .none
        sessionStartedAt = nil
        sessionID = nil
        sessionOptions = nil
        sessionUptimeBase = nil
        lastAcceptedPoint = nil
        accumulator = RecordingDistanceAccumulator()
        elevationFilter.reset()
        lastGraphPrefetchCoordinate = nil
        startRequested = false
        isActivating = false
        pendingResumeFlag = false
        acceptedFixRevision = 0
        journalTail = nil
        journalFlushTask?.cancel()
        journalFlushTask = nil
        pendingFixMergeTask?.cancel()
        pendingFixMergeTask = nil
        sharedStateTail = nil
        lastSharedSnapshotAt = nil
        lastSharedSnapshotPointCount = 0
        stats.reset()
        trace.reset()
    }

    nonisolated static func defaultTitle(
        for date: Date,
        calendar: Calendar = .current
    ) -> String {
        switch calendar.component(.hour, from: date) {
        case 5..<12:
            "Morning Hike"
        case 12..<17:
            "Afternoon Hike"
        case 17..<22:
            "Evening Hike"
        default:
            "Hike"
        }
    }

    private nonisolated static func routeDistance(
        _ route: [RouteCoordinate]
    ) -> Double {
        guard route.count > 1 else { return 0 }
        var distance = 0.0
        for index in 1..<route.count {
            distance += RouteGeometry.distanceMeters(
                from: CLLocationCoordinate2D(
                    latitude: route[index - 1].latitude,
                    longitude: route[index - 1].longitude
                ),
                to: CLLocationCoordinate2D(
                    latitude: route[index].latitude,
                    longitude: route[index].longitude
                )
            )
        }
        return distance
    }
}

extension HikeRecorder: CLLocationManagerDelegate {
    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        let ordered = locations.sorted { $0.timestamp < $1.timestamp }
        Task { @MainActor in
            for location in ordered {
                accept(location)
            }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(
        _ manager: CLLocationManager
    ) {
        Task { @MainActor in
            guard startRequested else { return }
            switch source.authorization {
            case .notDetermined:
                return
            case .denied:
                fail(
                    .locationDenied,
                    endLocationUpdates: sessionID != nil
                )
            case .authorized:
                if sessionID != nil {
                    if !source.hasFullAccuracy {
                        fail(.preciseLocationRequired)
                    }
                    return
                }
                await activateSessionIfPossible()
            }
        }
    }
}
