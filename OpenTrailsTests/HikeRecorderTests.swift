//
//  HikeRecorderTests.swift
//  OpenTrailsTests
//

import CoreLocation
import Foundation
import OpenTrailsShared
import SwiftData
import Testing
@testable import OpenTrails

@MainActor
private final class StubRecordingLocationSource: RecordingLocationSource {
    var authorization: RecordingLocationAuthorization = .authorized
    var hasFullAccuracy = true
    weak var delegateObject: AnyObject?

    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var authorizationRequests = 0
    private(set) var fullAccuracyRequests = 0
    private(set) var startedProfiles: [RecordingAccuracyProfile] = []

    var sourceDelegate: CLLocationManagerDelegate? {
        get { delegateObject as? CLLocationManagerDelegate }
        set { delegateObject = newValue }
    }

    func requestWhenInUseAuthorization() {
        authorizationRequests += 1
    }

    func requestTemporaryFullAccuracy() async {
        fullAccuracyRequests += 1
    }

    func startRecordingUpdates(profile: RecordingAccuracyProfile) {
        startCount += 1
        startedProfiles.append(profile)
    }

    func stopRecordingUpdates() {
        stopCount += 1
    }

    func deliver(_ location: CLLocation) {
        deliver([location])
    }

    func deliver(_ locations: [CLLocation]) {
        sourceDelegate?.locationManager?(
            CLLocationManager(),
            didUpdateLocations: locations
        )
    }

}

@MainActor
private final class StubRecordingElevationSource: RecordingElevationSource {
    var isAvailable = true
    private var handler: (@Sendable (Double) -> Void)?
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func start(
        deliveringRelativeAltitude handler: @escaping @Sendable (Double) -> Void
    ) {
        startCount += 1
        self.handler = handler
    }

    func stop() {
        stopCount += 1
        handler = nil
    }

    func deliver(_ relativeAltitude: Double) {
        handler?(relativeAltitude)
    }
}

private actor StubTrailGraphProvider: TrailGraphProviding {
    let graph: TrailGraph

    init(graph: TrailGraph) {
        self.graph = graph
    }

    func prefetch(around coordinate: CLLocationCoordinate2D) async throws {}

    func cachedGraph(
        covering coordinates: [CLLocationCoordinate2D]
    ) async throws -> TrailGraph? {
        graph
    }
}

private actor StubRecordingSharedStateStore:
    RecordingSharedStateStoring {
    private var snapshots: [SharedRecordingSnapshot] = []
    private var reloadFlags: [Bool] = []
    private var fixes: [SharedRecordingFix] = []
    private var removedFixIDs: Set<UUID> = []
    private var clearedSessionIDs: [UUID?] = []

    func save(
        _ snapshot: SharedRecordingSnapshot,
        reloadWidget: Bool
    ) {
        snapshots.append(snapshot)
        reloadFlags.append(reloadWidget)
    }

    func clear(sessionID: UUID?) {
        clearedSessionIDs.append(sessionID)
        if let sessionID {
            fixes.removeAll { $0.sessionID == sessionID }
        } else {
            fixes.removeAll()
        }
    }

    func pendingFixes(
        for sessionID: UUID
    ) -> [SharedRecordingFix] {
        fixes.filter { $0.sessionID == sessionID }
    }

    func removePendingFixes(ids: Set<UUID>) {
        removedFixIDs.formUnion(ids)
        fixes.removeAll { ids.contains($0.id) }
    }

    func setPendingFixes(_ fixes: [SharedRecordingFix]) {
        self.fixes = fixes
    }

    func savedSnapshots() -> [SharedRecordingSnapshot] {
        snapshots
    }

    func widgetReloadFlags() -> [Bool] {
        reloadFlags
    }

    func removedIDs() -> Set<UUID> {
        removedFixIDs
    }

    func clearCalls() -> [UUID?] {
        clearedSessionIDs
    }
}

private actor StubOnlineRecordingMatcher: RecordingOnlineMatching {
    let route: [RouteCoordinate]
    let delay: Duration?
    private(set) var callCount = 0

    init(route: [RouteCoordinate], delay: Duration? = nil) {
        self.route = route
        self.delay = delay
    }

    func match(
        points: [RecordingPoint]
    ) async throws -> [RouteCoordinate] {
        callCount += 1
        if let delay {
            try await Task.sleep(for: delay)
        }
        return route
    }

    func calls() -> Int {
        callCount
    }
}

@MainActor
@Suite("Hike recorder")
final class HikeRecorderTests {
    private let container: ModelContainer
    private let context: ModelContext
    private let source = StubRecordingLocationSource()
    private let clock = TestClock()
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "recording-sandbox-\(UUID().uuidString)",
            isDirectory: true
        )
    private var recorder: HikeRecorder?

    init() throws {
        container = try Fixture.modelContainer()
        context = ModelContext(container)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeRecorder(
        elevationSource: (any RecordingElevationSource)? = nil,
        trailGraphProvider: (any TrailGraphProviding)? = nil,
        onlineMatcher: (any RecordingOnlineMatching)? = nil,
        sharedStateStore: (any RecordingSharedStateStoring)? = nil,
        automaticallyRecovers: Bool = false,
        configureDefaults: (UserDefaults) -> Void = { _ in }
    ) -> HikeRecorder {
        let defaults = UserDefaults(
            suiteName: "hike-recorder-settings-\(UUID().uuidString)"
        )!
        configureDefaults(defaults)
        let recorder = HikeRecorder(
            container: container,
            source: source,
            elevationSource: elevationSource,
            trailGraphProvider: trailGraphProvider,
            onlineMatcher: onlineMatcher,
            defaults: defaults,
            onlineMatchingAvailable: { true },
            sharedStateStore: sharedStateStore,
            journalDirectory: directory,
            clock: clock.read,
            journalFlushDelay: .zero,
            automaticallyRecovers: automaticallyRecovers
        )
        self.recorder = recorder
        return recorder
    }

    @Test("recording accuracy is captured when the session starts")
    func recordingAccuracyProfileIsApplied() async {
        let recorder = makeRecorder { defaults in
            defaults.set(
                RecordingAccuracyProfile.batterySaver.rawValue,
                forKey: RecordingSettings.recordingAccuracyKey
            )
        }

        await recorder.start()

        #expect(source.startedProfiles.last == .batterySaver)
    }

    @Test("barometric elevation is fused into the saved route")
    func savesFusedElevation() async throws {
        let elevation = StubRecordingElevationSource()
        let recorder = makeRecorder(elevationSource: elevation)
        await recorder.start()
        #expect(elevation.startCount == 1)

        elevation.deliver(0)
        source.deliver(fix(latitude: 47.63))
        await settleDelegateHop()
        clock.advance(by: 10)
        elevation.deliver(10)
        source.deliver(fix(latitude: 47.6302))
        await settleDelegateHop()

        let hike = try await recorder.stop()

        #expect(elevation.stopCount >= 2)
        #expect(hike.route.count == 2)
        #expect(abs((hike.route[0].elevation ?? 0) - 600) < 0.01)
        #expect(abs((hike.route[1].elevation ?? 0) - 609.8) < 0.01)
    }

    @Test("a confident graph match becomes canonical and preserves the GPS trace")
    func savesMatchedAndRawRoutes() async throws {
        let from = TrailGraphNode(
            id: 1,
            coordinate: CLLocationCoordinate2D(
                latitude: 47.6298,
                longitude: 12.8599
            )
        )
        let to = TrailGraphNode(
            id: 2,
            coordinate: CLLocationCoordinate2D(
                latitude: 47.6305,
                longitude: 12.8599
            )
        )
        let graph = TrailGraph(
            nodes: [from, to],
            edges: [
                TrailGraphEdge(
                    id: TrailGraphEdgeID(wayID: 10, segmentIndex: 0),
                    fromNodeID: from.id,
                    toNodeID: to.id,
                    lengthMeters: RouteGeometry.distanceMeters(
                        from: from.coordinate,
                        to: to.coordinate
                    ),
                    name: "Matched Path",
                    hikingRouteName: nil,
                    sacScale: nil,
                    trailVisibility: nil,
                    access: nil,
                    surface: nil
                )
            ]
        )
        let recorder = makeRecorder(
            trailGraphProvider: StubTrailGraphProvider(graph: graph)
        )
        await recorder.start()
        source.deliver(fix(latitude: 47.63))
        await settleDelegateHop()
        clock.advance(by: 10)
        source.deliver(fix(latitude: 47.6302))
        await settleDelegateHop()

        let hike = try await recorder.stop()

        #expect(hike.rawRoute.count == 2)
        #expect(hike.route.count == 2)
        #expect(hike.route.allSatisfy {
            abs($0.longitude - 12.8599) < 0.00001
        })
        #expect(hike.rawRoute.allSatisfy {
            abs($0.longitude - 12.86) < 0.00001
        })
    }

    @Test("turning off raw-track retention keeps only matched geometry")
    func rawTrackRetentionCanBeDisabled() async throws {
        let from = TrailGraphNode(
            id: 1,
            coordinate: .init(latitude: 47.6298, longitude: 12.8599)
        )
        let to = TrailGraphNode(
            id: 2,
            coordinate: .init(latitude: 47.6305, longitude: 12.8599)
        )
        let graph = TrailGraph(
            nodes: [from, to],
            edges: [
                TrailGraphEdge(
                    id: .init(wayID: 10, segmentIndex: 0),
                    fromNodeID: from.id,
                    toNodeID: to.id,
                    lengthMeters: RouteGeometry.distanceMeters(
                        from: from.coordinate,
                        to: to.coordinate
                    ),
                    name: "Matched Path",
                    hikingRouteName: nil,
                    sacScale: nil,
                    trailVisibility: nil,
                    access: nil,
                    surface: nil
                )
            ]
        )
        let recorder = makeRecorder(
            trailGraphProvider: StubTrailGraphProvider(graph: graph),
            configureDefaults: { defaults in
                defaults.set(
                    false,
                    forKey: RecordingSettings.keepRawGPSTrackKey
                )
            }
        )
        await recorder.start()
        source.deliver(fix(latitude: 47.63))
        await settleDelegateHop()
        clock.advance(by: 10)
        source.deliver(fix(latitude: 47.6302))
        await settleDelegateHop()

        let hike = try await recorder.stop()

        #expect(hike.route.count == 2)
        #expect(hike.rawRoute.isEmpty)
    }

    @Test("online improvement runs only after recording stops")
    func optedInOnlineMatchRunsAtStop() async throws {
        let matchedRoute = [
            RouteCoordinate(
                latitude: 47.63,
                longitude: 12.8598,
                timestamp: clock.now
            ),
            RouteCoordinate(
                latitude: 47.6302,
                longitude: 12.8598,
                timestamp: clock.now.addingTimeInterval(10)
            )
        ]
        let onlineMatcher = StubOnlineRecordingMatcher(
            route: matchedRoute
        )
        let recorder = makeRecorder(
            onlineMatcher: onlineMatcher,
            configureDefaults: { defaults in
                defaults.set(
                    true,
                    forKey: RecordingSettings.improveAccuracyOnlineKey
                )
            }
        )
        await recorder.start()
        source.deliver(fix(latitude: 47.63))
        await settleDelegateHop()
        clock.advance(by: 10)
        source.deliver(fix(latitude: 47.6302))
        await settleDelegateHop()

        #expect(await onlineMatcher.calls() == 0)
        let hike = try await recorder.stop()

        #expect(await onlineMatcher.calls() == 1)
        #expect(hike.route == matchedRoute)
        #expect(hike.rawRoute.count == 2)
    }

    @Test("turning off trail snapping preserves the filtered GPS route")
    func disablingTrailSnappingSkipsOnlineMatching() async throws {
        let onlineMatcher = StubOnlineRecordingMatcher(
            route: [
                RouteCoordinate(
                    latitude: 47.63,
                    longitude: 12.8598,
                    timestamp: clock.now
                ),
                RouteCoordinate(
                    latitude: 47.6302,
                    longitude: 12.8598,
                    timestamp: clock.now.addingTimeInterval(10)
                )
            ]
        )
        let recorder = makeRecorder(
            onlineMatcher: onlineMatcher,
            configureDefaults: { defaults in
                defaults.set(
                    false,
                    forKey: RecordingSettings.snapToTrailsKey
                )
                defaults.set(
                    true,
                    forKey: RecordingSettings.improveAccuracyOnlineKey
                )
            }
        )
        await recorder.start()
        source.deliver(fix(latitude: 47.63))
        await settleDelegateHop()
        clock.advance(by: 10)
        source.deliver(fix(latitude: 47.6302))
        await settleDelegateHop()

        let hike = try await recorder.stop()

        #expect(await onlineMatcher.calls() == 0)
        #expect(hike.route.allSatisfy {
            abs($0.longitude - 12.86) < 0.00001
        })
        #expect(hike.rawRoute.isEmpty)
    }

    @Test("widget anchors are journalled and shared state clears at Stop")
    func widgetFixesAreFoldedIntoTheRecording() async throws {
        let sharedStore = StubRecordingSharedStateStore()
        let recorder = makeRecorder(sharedStateStore: sharedStore)
        await recorder.start()
        source.deliver(fix(latitude: 47.63))
        await settleDelegateHop()

        let snapshots = await sharedStore.savedSnapshots()
        let sessionID = try #require(snapshots.last?.sessionID)
        let widgetFix = SharedRecordingFix(
            sessionID: sessionID,
            latitude: 47.6302,
            longitude: 12.86,
            timestamp: clock.now.addingTimeInterval(20),
            horizontalAccuracy: 60
        )
        await sharedStore.setPendingFixes([widgetFix])
        recorder.sceneDidBecomeActive()
        for _ in 0..<100 {
            if recorder.stats.pointCount == 2 {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(recorder.stats.pointCount == 2)
        #expect(recorder.trace.tail.count == 2)

        clock.advance(by: 40)
        source.deliver(fix(latitude: 47.6304))
        await settleDelegateHop()
        let hike = try await recorder.stop()

        #expect(hike.route.count == 3)
        #expect(await sharedStore.removedIDs().contains(widgetFix.id))
        #expect(
            await sharedStore.clearCalls().contains {
                $0 == sessionID
            }
        )
    }

    @Test("periodic snapshots do not force extra WidgetKit reloads")
    func periodicSnapshotsDoNotForceReloads() async throws {
        let sharedStore = StubRecordingSharedStateStore()
        let recorder = makeRecorder(sharedStateStore: sharedStore)
        await recorder.start()
        source.deliver(fix(latitude: 47.63))
        await settleDelegateHop()
        clock.advance(by: 15 * 60)
        source.deliver(fix(latitude: 47.6302))
        await settleDelegateHop()

        for _ in 0..<100 {
            if await sharedStore.savedSnapshots().count >= 3 {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(await sharedStore.widgetReloadFlags().last == false)
    }

    private func fix(
        latitude: Double,
        accuracy: CLLocationAccuracy = 8
    ) -> CLLocation {
        CLLocation(
            coordinate: CLLocationCoordinate2D(
                latitude: latitude,
                longitude: 12.86
            ),
            altitude: 600,
            horizontalAccuracy: accuracy,
            verticalAccuracy: 5,
            course: 0,
            speed: 1,
            timestamp: clock.now
        )
    }

    @Test("a hike is written once at Stop and keeps its raw trace")
    func savesAtStop() async throws {
        let recorder = makeRecorder()
        await recorder.start()
        #expect(source.startCount == 1)

        source.deliver(fix(latitude: 47.63))
        await settleDelegateHop()
        clock.advance(by: 10)
        source.deliver(fix(latitude: 47.6302))
        await settleDelegateHop()

        #expect(
            try context.fetch(FetchDescriptor<Hike>()).isEmpty,
            "recording must not rewrite a SwiftData route per fix"
        )
        #expect(recorder.stats.pointCount == 2)

        let hike = try await recorder.stop()

        #expect(try context.fetch(FetchDescriptor<Hike>()).count == 1)
        #expect(hike.route.count == 2)
        #expect(
            hike.rawRoute.isEmpty,
            "with no matcher yet the route is the raw trace; a second copy is pure cost"
        )
        #expect(hike.distanceMeters > 20)
        #expect(recorder.phase == .idle)
    }

    @Test("the journal falls back to Application Support without an App Group")
    func journalFallsBackOutsideTheAppGroup() {
        let appGroup = URL(filePath: "/tmp/group.example")
        let support = URL(filePath: "/tmp/support.example")

        #expect(
            HikeRecorder.journalDirectory(
                appGroupContainer: appGroup,
                applicationSupport: support
            ) == appGroup.appendingPathComponent("Recording", isDirectory: true),
            "the shared container is still preferred, for the widget payload to come"
        )
        #expect(
            HikeRecorder.journalDirectory(
                appGroupContainer: nil,
                applicationSupport: support
            ) == support.appendingPathComponent("Recording", isDirectory: true),
            "an unprovisioned App Group must not be the difference between recording and refusing"
        )
        #expect(
            HikeRecorder.journalDirectory(
                appGroupContainer: nil,
                applicationSupport: nil
            ) == nil
        )
    }

    @Test("a paused session is not described as recording")
    func pausedSessionIsNotCapturingFixes() async {
        let recorder = makeRecorder()
        await recorder.start()
        source.deliver(fix(latitude: 47.63))
        await settleDelegateHop()
        #expect(recorder.isCapturingFixes)

        recorder.pause()

        #expect(recorder.isActive, "still reachable from the hikes list")
        #expect(!recorder.isCapturingFixes, "but no longer taking fixes")
    }

    @Test("elapsed time comes from a monotonic source, not the wall clock")
    func elapsedTimeSurvivesAClockChange() async {
        let uptime = TestClock(Date(timeIntervalSince1970: 1_000))
        let recorder = HikeRecorder(
            container: container,
            source: source,
            journalDirectory: directory,
            clock: clock.read,
            uptime: { uptime.now.timeIntervalSince1970 },
            journalFlushDelay: .zero,
            automaticallyRecovers: false
        )
        await recorder.start()

        uptime.advance(by: 90)
        // Someone's phone picks up an NTP correction an hour into the walk.
        clock.advance(by: -3_600)

        #expect(recorder.elapsedSeconds() == 90)
    }

    @Test("batched Core Location delivery keeps every accepted fix")
    func batchedDeliveryIsRecordedInTimestampOrder() async {
        let recorder = makeRecorder()
        await recorder.start()
        let first = fix(latitude: 47.63)
        clock.advance(by: 10)
        let second = fix(latitude: 47.6302)

        source.deliver([second, first])
        await settleDelegateHop()

        #expect(recorder.stats.pointCount == 2)
    }

    @Test("a lone accepted fix is flushed without waiting for ten points")
    func sparseFixesAreFlushedOnDeadline() async throws {
        let recorder = makeRecorder()
        await recorder.start()
        source.deliver(fix(latitude: 47.63))
        await settleDelegateHop()
        for _ in 0..<16 { await Task.yield() }

        let journal = TrackJournal(directory: directory)
        let session = try #require(try await journal.loadSession())
        #expect(session.points.count == 1)
    }

    @Test("pause and resume do not add the distance crossed while paused")
    func pauseDoesNotBridgeGap() async throws {
        let recorder = makeRecorder()
        await recorder.start()
        source.deliver(fix(latitude: 47.63))
        await settleDelegateHop()
        clock.advance(by: 60)
        source.deliver(fix(latitude: 47.631))
        await settleDelegateHop()

        recorder.pause()
        clock.advance(by: 300)
        await recorder.resume()
        source.deliver(fix(latitude: 47.64))
        await settleDelegateHop()
        clock.advance(by: 60)
        source.deliver(fix(latitude: 47.641))
        await settleDelegateHop()

        let hike = try await recorder.stop()
        #expect(abs(hike.distanceMeters - 222) < 5)
        #expect(hike.route.count == 4, "the drawn route remains continuous in v1")
    }

    @Test("reduced accuracy refuses to start a meaningless trace")
    func reducedAccuracyIsRefused() async {
        source.hasFullAccuracy = false
        let recorder = makeRecorder()

        await recorder.start()

        #expect(source.fullAccuracyRequests == 1)
        #expect(recorder.phase == .failed(.preciseLocationRequired))
        #expect(source.startCount == 0)
    }

    @Test("losing precise location pauses an active recording with an error")
    func preciseLocationRevokedMidRecording() async {
        let recorder = makeRecorder()
        await recorder.start()
        source.hasFullAccuracy = false

        recorder.locationManagerDidChangeAuthorization(CLLocationManager())
        await settleDelegateHop()

        #expect(recorder.phase == .failed(.preciseLocationRequired))
        #expect(source.stopCount == 1)
    }

    @Test("revoking location stops every active recording sensor")
    func locationRevokedMidRecording() async {
        let elevation = StubRecordingElevationSource()
        let recorder = makeRecorder(elevationSource: elevation)
        await recorder.start()
        source.authorization = .denied

        recorder.locationManagerDidChangeAuthorization(CLLocationManager())
        await settleDelegateHop()

        #expect(recorder.phase == .failed(.locationDenied))
        #expect(source.stopCount == 1)
        #expect(elevation.stopCount >= 2)
    }

    @Test("a completed journal is saved on the next launch")
    func completedJournalIsRecovered() async throws {
        let sessionID = UUID()
        let journal = TrackJournal(directory: directory, clock: clock.read)
        try await journal.start(sessionID: sessionID, startedAt: clock.now)
        try await journal.append(
            RecordingPoint(
                latitude: 47.63,
                longitude: 12.86,
                timestamp: clock.now,
                horizontalAccuracy: 8
            )
        )
        clock.advance(by: 10)
        try await journal.append(
            RecordingPoint(
                latitude: 47.6302,
                longitude: 12.86,
                timestamp: clock.now,
                horizontalAccuracy: 8
            )
        )
        try await journal.finish(at: clock.now)

        let recorder = makeRecorder()
        await recorder.recoverOpenSession()

        let hikes = try context.fetch(FetchDescriptor<Hike>())
        #expect(hikes.count == 1)
        #expect(hikes.first?.id == sessionID)
        #expect(recorder.phase == .idle)
        #expect(!FileManager.default.fileExists(atPath: journal.journalURL.path))
    }

    @Test("an explicitly paused session stays paused after relaunch")
    func pausedSessionDoesNotAutoResume() async throws {
        let journal = TrackJournal(directory: directory, clock: clock.read)
        try await journal.start(sessionID: UUID(), startedAt: clock.now)
        try await journal.append(
            RecordingPoint(
                latitude: 47.63,
                longitude: 12.86,
                timestamp: clock.now,
                horizontalAccuracy: 8
            )
        )
        try await journal.pause(at: clock.now)
        try await journal.close()

        let recorder = makeRecorder()
        await recorder.recoverOpenSession()

        #expect(recorder.phase == .paused)
        #expect(source.startCount == 0)
        guard case .needsDecision = recorder.recoveryState else {
            Issue.record("the recovered pause should be explained to the user")
            return
        }
    }

    @Test("a recent open session resumes after relaunch")
    func recentOpenSessionAutoResumes() async throws {
        let journal = TrackJournal(directory: directory, clock: clock.read)
        try await journal.start(sessionID: UUID(), startedAt: clock.now)
        try await journal.append(
            RecordingPoint(
                latitude: 47.63,
                longitude: 12.86,
                timestamp: clock.now,
                horizontalAccuracy: 8
            )
        )
        try await journal.close()

        let recorder = makeRecorder()
        await recorder.recoverOpenSession()

        #expect(recorder.phase == .recording)
        #expect(recorder.recoveryState == .resumed)
        #expect(source.startCount == 1)
        #expect(recorder.stats.pointCount == 1)
    }

    @Test("a stale open session waits for a recovery decision")
    func staleOpenSessionDoesNotAutoResume() async throws {
        let sessionID = UUID()
        let journal = TrackJournal(directory: directory, clock: clock.read)
        try await journal.start(sessionID: sessionID, startedAt: clock.now)
        try await journal.append(
            RecordingPoint(
                latitude: 47.63,
                longitude: 12.86,
                timestamp: clock.now,
                horizontalAccuracy: 8
            )
        )
        try await journal.close()
        clock.advance(by: 24 * 60 * 60)

        let sharedStore = StubRecordingSharedStateStore()
        await sharedStore.setPendingFixes([
            SharedRecordingFix(
                sessionID: sessionID,
                latitude: 47.6302,
                longitude: 12.86,
                timestamp: clock.now.addingTimeInterval(-60),
                horizontalAccuracy: 50
            )
        ])
        let recorder = makeRecorder(sharedStateStore: sharedStore)

        await recorder.recoverOpenSession()

        #expect(recorder.phase == .paused)
        #expect(source.startCount == 0)
        #expect(recorder.stats.pointCount == 2)
        guard case .needsDecision(let summary) = recorder.recoveryState else {
            Issue.record("a stale session should require a recovery decision")
            return
        }
        #expect(summary.lastUpdatedAt == clock.now.addingTimeInterval(-86_400))
    }

    @Test("automatic recovery claims the journal before Start can replace it")
    func automaticRecoveryBlocksStart() async throws {
        let sessionID = UUID()
        let journal = TrackJournal(directory: directory, clock: clock.read)
        try await journal.start(sessionID: sessionID, startedAt: clock.now)
        try await journal.append(
            RecordingPoint(
                latitude: 47.63,
                longitude: 12.86,
                timestamp: clock.now,
                horizontalAccuracy: 8
            )
        )
        try await journal.close()

        let recorder = makeRecorder(automaticallyRecovers: true)

        #expect(recorder.phase == .recovering)
        #expect(recorder.isActive)
        await recorder.start()
        for _ in 0..<100 where recorder.phase == .recovering {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(recorder.phase == .recording)
        #expect(recorder.stats.pointCount == 1)
        let recovered = try #require(try await journal.loadSession())
        #expect(recovered.metadata.sessionID == sessionID)
        #expect(recovered.points.count == 1)
    }

    @Test("a second Stop cannot start another persistence operation")
    func stopIsNotReentrant() async throws {
        let matchedRoute = [
            RouteCoordinate(
                latitude: 47.63,
                longitude: 12.8598,
                timestamp: clock.now
            ),
            RouteCoordinate(
                latitude: 47.6302,
                longitude: 12.8598,
                timestamp: clock.now.addingTimeInterval(10)
            )
        ]
        let onlineMatcher = StubOnlineRecordingMatcher(
            route: matchedRoute,
            delay: .milliseconds(100)
        )
        let recorder = makeRecorder(
            onlineMatcher: onlineMatcher,
            configureDefaults: { defaults in
                defaults.set(
                    true,
                    forKey: RecordingSettings.improveAccuracyOnlineKey
                )
            }
        )
        await recorder.start()
        source.deliver(fix(latitude: 47.63))
        await settleDelegateHop()
        clock.advance(by: 10)
        source.deliver(fix(latitude: 47.6302))
        await settleDelegateHop()

        let firstStop = Task { try await recorder.stop() }
        while recorder.phase != .saving {
            await Task.yield()
        }
        do {
            _ = try await recorder.stop()
            Issue.record("a second Stop should be refused while saving")
        } catch let failure as RecordingFailure {
            guard case .save = failure else {
                Issue.record("the second Stop returned the wrong failure")
                return
            }
        } catch {
            Issue.record("the second Stop returned an unexpected error")
            return
        }
        let hike = try await firstStop.value

        #expect(hike.route == matchedRoute)
        #expect(try context.fetch(FetchDescriptor<Hike>()).count == 1)
        #expect(recorder.phase == .idle)
    }

    @Test("pending widget anchors are merged before recovery resumes")
    func pendingWidgetFixesMergeDuringRecovery() async throws {
        let sessionID = UUID()
        let journal = TrackJournal(directory: directory, clock: clock.read)
        try await journal.start(sessionID: sessionID, startedAt: clock.now)
        try await journal.append(
            RecordingPoint(
                latitude: 47.63,
                longitude: 12.86,
                timestamp: clock.now,
                horizontalAccuracy: 8
            )
        )
        try await journal.close()

        let sharedStore = StubRecordingSharedStateStore()
        let widgetFix = SharedRecordingFix(
            sessionID: sessionID,
            latitude: 47.6302,
            longitude: 12.86,
            timestamp: clock.now.addingTimeInterval(20),
            horizontalAccuracy: 50
        )
        await sharedStore.setPendingFixes([widgetFix])
        let recorder = makeRecorder(sharedStateStore: sharedStore)

        await recorder.recoverOpenSession()

        #expect(recorder.phase == .recording)
        #expect(recorder.stats.pointCount == 2)
        #expect(recorder.trace.tail.count == 2)
        #expect(await sharedStore.removedIDs().contains(widgetFix.id))
        let recovered = try #require(try await journal.loadSession())
        #expect(recovered.points.count == 2)
        #expect(recovered.points.last?.flags.contains(.widgetSourced) == true)
    }

    @Test("recovery does not duplicate a hike saved before journal cleanup")
    func completedJournalRecoveryIsIdempotent() async throws {
        let sessionID = UUID()
        context.insert(
            Hike(
                id: sessionID,
                title: "Already Saved",
                distanceMeters: 10,
                route: Fixture.ridgeRoute
            )
        )
        try context.save()

        let journal = TrackJournal(directory: directory, clock: clock.read)
        try await journal.start(sessionID: sessionID, startedAt: clock.now)
        try await journal.append(
            RecordingPoint(
                latitude: 47.63,
                longitude: 12.86,
                timestamp: clock.now,
                horizontalAccuracy: 8
            )
        )
        clock.advance(by: 10)
        try await journal.append(
            RecordingPoint(
                latitude: 47.6302,
                longitude: 12.86,
                timestamp: clock.now,
                horizontalAccuracy: 8
            )
        )
        try await journal.finish(at: clock.now)

        let recorder = makeRecorder()
        await recorder.recoverOpenSession()

        let hikes = try context.fetch(FetchDescriptor<Hike>())
        #expect(hikes.count == 1)
        #expect(hikes.first?.title == "Already Saved")
        #expect(!FileManager.default.fileExists(atPath: journal.journalURL.path))
    }

    @Test("every recorder failure carries user-facing copy", arguments: [
        RecordingFailure.locationDenied,
        .preciseLocationRequired,
        .storageUnavailable,
        .storage("Disk full"),
        .tooShort,
        .save("Store unavailable")
    ])
    func failuresAreExplained(_ failure: RecordingFailure) throws {
        #expect(!(try #require(failure.errorDescription)).isEmpty)
        #expect(!(try #require(failure.recoverySuggestion)).isEmpty)
    }
}
