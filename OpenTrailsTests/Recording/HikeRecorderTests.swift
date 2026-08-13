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

    func startRecordingUpdates() {
        startCount += 1
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

@MainActor
private final class StubRecordingMotionSource: RecordingMotionSource {
    var isAvailable = true
    private var handler: (@Sendable (RecordingMotionState) -> Void)?
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func start(
        deliveringState handler: @escaping @Sendable (
            RecordingMotionState
        ) -> Void
    ) {
        startCount += 1
        self.handler = handler
    }

    func stop() {
        stopCount += 1
        handler = nil
    }

    func deliver(_ state: RecordingMotionState) {
        handler?(state)
    }
}

private actor StubTrailGraphProvider: TrailGraphProviding {
    let graph: TrailGraph
    let cachedGraphDelay: Duration?
    private var prefetchedRegions: [TrailGraphRegion] = []

    init(
        graph: TrailGraph,
        cachedGraphDelay: Duration? = nil
    ) {
        self.graph = graph
        self.cachedGraphDelay = cachedGraphDelay
    }

    nonisolated func region(
        containing coordinate: CLLocationCoordinate2D
    ) -> TrailGraphRegion? {
        guard Mercator.isRepresentable(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude
        ) else {
            return nil
        }
        return TrailGraphRegion(
            zoom: 12,
            x: Int(floor((coordinate.longitude + 180) * 10)),
            y: Int(floor((coordinate.latitude + 90) * 10))
        )
    }

    func prefetch(around coordinate: CLLocationCoordinate2D) async throws {
        if let region = region(containing: coordinate) {
            prefetchedRegions.append(region)
        }
    }

    func cachedGraph(
        covering coordinates: [CLLocationCoordinate2D]
    ) async throws -> TrailGraph? {
        if let cachedGraphDelay {
            try await Task.sleep(for: cachedGraphDelay)
        }
        return graph
    }

    func prefetches() -> [TrailGraphRegion] {
        prefetchedRegions
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
        motionSource: (any RecordingMotionSource)? = nil,
        trailGraphProvider: (any TrailGraphProviding)? = nil,
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
            motionSource: motionSource,
            trailGraphProvider: trailGraphProvider,
            defaults: defaults,
            sharedStateStore: sharedStateStore,
            journalDirectory: directory,
            clock: clock.read,
            journalFlushDelay: .zero,
            automaticallyRecovers: automaticallyRecovers
        )
        self.recorder = recorder
        return recorder
    }

    private func liveMatchingGraph() -> TrailGraph {
        let from = TrailGraphNode(
            id: 101,
            coordinate: CLLocationCoordinate2D(
                latitude: 47.6298,
                longitude: 12.8599
            )
        )
        let to = TrailGraphNode(
            id: 102,
            coordinate: CLLocationCoordinate2D(
                latitude: 47.6305,
                longitude: 12.8599
            )
        )
        return TrailGraph(
            nodes: [from, to],
            edges: [
                TrailGraphEdge(
                    id: TrailGraphEdgeID(wayID: 101, segmentIndex: 0),
                    fromNodeID: from.id,
                    toNodeID: to.id,
                    lengthMeters: RouteGeometry.distanceMeters(
                        from: from.coordinate,
                        to: to.coordinate
                    ),
                    name: "Live Path",
                    hikingRouteName: nil,
                    sacScale: nil,
                    trailVisibility: nil,
                    access: nil,
                    surface: nil
                )
            ]
        )
    }

    private func ambiguityGraph() -> TrailGraph {
        let definitions: [(Int64, Double, Double)] = [
            (1, 47.6300, 12.8600),
            (2, 47.6302, 12.8600),
            (3, 47.6340, 12.8600),
            (4, 47.6340, 12.8640),
            (5, 47.6302, 12.8640),
            (6, 47.6300, 12.8640),
            (7, 47.6260, 12.8600),
            (8, 47.6260, 12.8640)
        ]
        let nodes = definitions.map {
            TrailGraphNode(
                id: $0.0,
                coordinate: CLLocationCoordinate2D(
                    latitude: $0.1,
                    longitude: $0.2
                )
            )
        }
        let byID = Dictionary(
            uniqueKeysWithValues: nodes.map { ($0.id, $0) }
        )
        let ways: [(Int64, [Int64], String)] = [
            (10, [1, 2], "Fork Trail"),
            (11, [2, 3, 4, 5], "North Fork"),
            (12, [2, 7, 8, 5], "South Fork"),
            (13, [5, 6], "Fork Trail")
        ]
        var edges: [TrailGraphEdge] = []
        for way in ways {
            for index in 0..<(way.1.count - 1) {
                let from = byID[way.1[index]]!
                let to = byID[way.1[index + 1]]!
                edges.append(
                    TrailGraphEdge(
                        id: TrailGraphEdgeID(
                            wayID: way.0,
                            segmentIndex: index
                        ),
                        fromNodeID: from.id,
                        toNodeID: to.id,
                        lengthMeters: RouteGeometry.distanceMeters(
                            from: from.coordinate,
                            to: to.coordinate
                        ),
                        name: way.2,
                        hikingRouteName: nil,
                        sacScale: nil,
                        trailVisibility: nil,
                        access: nil,
                        surface: nil
                    )
                )
            }
        }
        return TrailGraph(nodes: nodes, edges: edges)
    }

    private func savedHike(
        from outcome: RecordingStopOutcome
    ) throws -> Hike {
        guard case .saved(let hike) = outcome else {
            Issue.record("the recording unexpectedly required review")
            throw RecordingFailure.save(
                "The recording unexpectedly required review."
            )
        }
        return hike
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

        let hike = try savedHike(from: await recorder.stop())

        #expect(elevation.stopCount >= 2)
        #expect(hike.route.count == 2)
        #expect(abs((hike.route[0].elevation ?? 0) - 600) < 0.01)
        #expect(abs((hike.route[1].elevation ?? 0) - 609.8) < 0.01)
    }

    @Test("motion activity preserves a non-pedestrian segment")
    func nonPedestrianMotionIsAcceptedAndSaved() async throws {
        let motion = StubRecordingMotionSource()
        let recorder = makeRecorder(motionSource: motion)
        await recorder.start()
        motion.deliver(.nonPedestrian)
        await settleDelegateHop()

        source.deliver(fix(latitude: 47.63, speed: 1))
        await settleDelegateHop()
        clock.advance(by: 5)
        source.deliver(
            fix(
                latitude: 47.63 + 100 / 111_000,
                speed: 1
            )
        )
        await settleDelegateHop()

        #expect(recorder.stats.pointCount == 2)
        let hike = try savedHike(from: await recorder.stop())
        #expect(hike.route.allSatisfy { $0.motion == .nonPedestrian })
        #expect(motion.startCount == 1)
        #expect(motion.stopCount >= 2)
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

        for _ in 0..<100 {
            if recorder.stats.matchedTrailName == "Matched Path" {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(recorder.stats.matchedTrailName == "Matched Path")
        #expect(recorder.trace.tail.allSatisfy {
            abs($0.longitude - 12.8599) < 0.00001
        })

        let hike = try savedHike(from: await recorder.stop())

        #expect(hike.rawRoute.count == 2)
        #expect(hike.route.count == 2)
        #expect(hike.route.allSatisfy {
            abs($0.longitude - 12.8599) < 0.00001
        })
        #expect(hike.rawRoute.allSatisfy {
            abs($0.longitude - 12.86) < 0.00001
        })
    }

    @Test("live trail name clears when the current leg cannot be matched")
    func liveTrailNameClearsForAnUnmatchedTail() async throws {
        let recorder = makeRecorder(
            trailGraphProvider: StubTrailGraphProvider(
                graph: liveMatchingGraph()
            )
        )
        await recorder.start()
        source.deliver(fix(latitude: 47.63))
        await settleDelegateHop()
        clock.advance(by: 10)
        source.deliver(fix(latitude: 47.6302))
        await settleDelegateHop()

        for _ in 0..<100 {
            if recorder.stats.matchedTrailName == "Live Path" {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(recorder.stats.matchedTrailName == "Live Path")

        clock.advance(by: 30)
        source.deliver(fix(latitude: 47.632))
        await settleDelegateHop()
        for _ in 0..<100 {
            if recorder.stats.matchedTrailName == nil {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(recorder.stats.pointCount == 3)
        #expect(recorder.stats.matchedTrailName == nil)
        await recorder.discard()
    }

    @Test("live matching catches up when a fix arrives during graph loading")
    func slowLiveMatchDoesNotStarve() async throws {
        let recorder = makeRecorder(
            trailGraphProvider: StubTrailGraphProvider(
                graph: liveMatchingGraph(),
                cachedGraphDelay: .milliseconds(50)
            )
        )
        await recorder.start()
        source.deliver(fix(latitude: 47.63))
        await settleDelegateHop()
        clock.advance(by: 10)
        source.deliver(fix(latitude: 47.6302))
        await settleDelegateHop()
        clock.advance(by: 10)
        source.deliver(fix(latitude: 47.6304))
        await settleDelegateHop()

        for _ in 0..<100 {
            if recorder.stats.matchedTrailName == "Live Path",
               recorder.trace.tail.allSatisfy({
                   abs($0.longitude - 12.8599) < 0.000_01
               }) {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(recorder.stats.matchedTrailName == "Live Path")
        #expect(recorder.trace.tail.allSatisfy {
            abs($0.longitude - 12.8599) < 0.000_01
        })
        await recorder.discard()
    }

    @Test("ambiguous gaps wait for review before writing a hike")
    func ambiguityReviewDefersPersistence() async throws {
        let sharedStore = StubRecordingSharedStateStore()
        let recorder = makeRecorder(
            trailGraphProvider: StubTrailGraphProvider(
                graph: ambiguityGraph()
            ),
            sharedStateStore: sharedStore
        )
        await recorder.start()
        source.deliver(fix(latitude: 47.63, longitude: 12.86))
        await settleDelegateHop()
        clock.advance(by: 720)
        source.deliver(fix(latitude: 47.63, longitude: 12.864))
        await settleDelegateHop()

        let outcome = try await recorder.stop()
        guard case .needsReview = outcome else {
            Issue.record("the sparse fork should require review")
            return
        }

        #expect(recorder.phase == .reviewing)
        #expect(try context.fetch(FetchDescriptor<Hike>()).isEmpty)
        let review = try #require(recorder.ambiguityReview)
        let ambiguity = try #require(review.current)
        #expect(ambiguity.alternatives.count >= 2)
        #expect(recorder.trace.reviewSegment.count == 2)
        #expect(
            FileManager.default.fileExists(
                atPath: TrackJournal(directory: directory).journalURL.path
            )
        )
        let sessionID = try #require(
            await sharedStore.savedSnapshots().last?.sessionID
        )
        let lateWidgetFix = SharedRecordingFix(
            sessionID: sessionID,
            latitude: 47.631,
            longitude: 12.862,
            timestamp: clock.now.addingTimeInterval(60),
            horizontalAccuracy: 50
        )
        await sharedStore.setPendingFixes([lateWidgetFix])
        recorder.sceneDidBecomeActive()
        try await Task.sleep(for: .milliseconds(50))
        #expect(recorder.stats.pointCount == 2)
        #expect(!(await sharedStore.removedIDs()).contains(lateWidgetFix.id))

        let alternative = try #require(ambiguity.alternatives.first)
        recorder.selectAmbiguityChoice(
            .alternative(alternative.id)
        )
        #expect(recorder.trace.reviewSegment.count > 2)

        let hike = try await recorder.saveReviewedRecording()

        #expect(hike.route.count > 2)
        #expect(hike.rawRoute.count == 2)
        #expect(try context.fetch(FetchDescriptor<Hike>()).count == 1)
        #expect(recorder.phase == .idle)
        #expect(
            !FileManager.default.fileExists(
                atPath: TrackJournal(directory: directory).journalURL.path
            )
        )
    }

    @Test("trail graph prefetch follows the recording into new regions")
    func trailGraphPrefetchExtendsWithTheRecording() async {
        let provider = StubTrailGraphProvider(graph: .empty)
        let recorder = makeRecorder(trailGraphProvider: provider)
        await recorder.start()

        source.deliver(fix(latitude: 47.63, longitude: 12.86))
        await settleDelegateHop()
        clock.advance(by: 1_000)
        source.deliver(fix(latitude: 47.63, longitude: 12.96))
        await settleDelegateHop()

        for _ in 0..<100 {
            if await provider.prefetches().count == 2 {
                break
            }
            await Task.yield()
        }

        let regions = await provider.prefetches()
        #expect(regions.count == 2)
        #expect(Set(regions).count == 2)
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

        let hike = try savedHike(from: await recorder.stop())

        #expect(hike.route.count == 2)
        #expect(hike.rawRoute.isEmpty)
    }

    @Test("turning off trail snapping preserves the filtered GPS route")
    func disablingTrailSnappingPreservesGPSRoute() async throws {
        let recorder = makeRecorder(
            configureDefaults: { defaults in
                defaults.set(
                    false,
                    forKey: RecordingSettings.snapToTrailsKey
                )
            }
        )
        await recorder.start()
        source.deliver(fix(latitude: 47.63))
        await settleDelegateHop()
        clock.advance(by: 10)
        source.deliver(fix(latitude: 47.6302))
        await settleDelegateHop()
        let hike = try savedHike(from: await recorder.stop())

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
        let hike = try savedHike(from: await recorder.stop())

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
        longitude: Double = 12.86,
        accuracy: CLLocationAccuracy = 8,
        speed: CLLocationSpeed = 1
    ) -> CLLocation {
        CLLocation(
            coordinate: CLLocationCoordinate2D(
                latitude: latitude,
                longitude: longitude
            ),
            altitude: 600,
            horizontalAccuracy: accuracy,
            verticalAccuracy: 5,
            course: 0,
            speed: speed,
            timestamp: clock.now
        )
    }

    private func acceleratedLocations(
        from track: GPXImport.Track,
        endingAt endDate: Date,
        duration: TimeInterval = 20
    ) -> [CLLocation] {
        guard track.points.count > 1 else { return [] }
        let interval = duration / Double(track.points.count - 1)
        let startedAt = endDate.addingTimeInterval(-duration)

        return track.points.enumerated().map { index, point in
            let speed: CLLocationSpeed
            if index == 0 {
                speed = 0
            } else {
                speed = RouteGeometry.distanceMeters(
                    from: track.points[index - 1].coordinate,
                    to: point.coordinate
                ) / interval
            }
            return CLLocation(
                coordinate: point.coordinate,
                altitude: point.elevation ?? 0,
                horizontalAccuracy: 5,
                verticalAccuracy: point.elevation == nil ? -1 : 5,
                course: 0,
                speed: speed,
                timestamp: startedAt.addingTimeInterval(
                    Double(index) * interval
                )
            )
        }
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

        let hike = try savedHike(from: await recorder.stop())

        #expect(try context.fetch(FetchDescriptor<Hike>()).count == 1)
        #expect(hike.route.count == 2)
        #expect(
            hike.rawRoute.isEmpty,
            "with no matcher yet the route is the raw trace; a second copy is pure cost"
        )
        #expect(hike.distanceMeters > 20)
        #expect(recorder.phase == .idle)
    }

    @Test("the bundled Thumsee simulator route records and saves end to end")
    func bundledDemoRouteRecordsHike() async throws {
        let routeURL = try #require(
            Bundle.main.url(
                forResource: "ThumseeLoopFast",
                withExtension: "gpx"
            )
        )
        let track = try GPXImport.load(from: routeURL)
        let locations = acceleratedLocations(
            from: track,
            endingAt: clock.now
        )
        let recorder = makeRecorder()

        await recorder.start()
        source.deliver(locations)
        await settleDelegateHop()

        let acceptedPointCount = recorder.stats.pointCount
        let hike = try savedHike(from: await recorder.stop())
        let first = try #require(hike.route.first)
        let last = try #require(hike.route.last)
        let sourceFirst = try #require(track.points.first)
        let sourceLast = try #require(track.points.last)

        #expect(track.points.count > 300)
        #expect(acceptedPointCount > 250)
        #expect(hike.route.count == acceptedPointCount)
        #expect(
            RouteGeometry.distanceMeters(
                from: first.clCoordinate,
                to: sourceFirst.coordinate
            ) < 1
        )
        #expect(
            RouteGeometry.distanceMeters(
                from: last.clCoordinate,
                to: sourceLast.coordinate
            ) < 1
        )
        #expect(
            abs(hike.distanceMeters - track.distanceMeters)
                < track.distanceMeters * 0.15
        )
        #expect(hike.rawRoute.isEmpty)
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

        let hike = try savedHike(from: await recorder.stop())
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

    @Test("a completed ambiguous journal returns to review after relaunch")
    func ambiguousCompletedJournalRecoversIntoReview() async throws {
        let sessionID = UUID()
        let journal = TrackJournal(directory: directory, clock: clock.read)
        try await journal.start(
            sessionID: sessionID,
            startedAt: clock.now,
            recordingOptions: .defaults
        )
        try await journal.append(
            RecordingPoint(
                latitude: 47.63,
                longitude: 12.86,
                timestamp: clock.now,
                horizontalAccuracy: 8
            )
        )
        clock.advance(by: 720)
        try await journal.append(
            RecordingPoint(
                latitude: 47.63,
                longitude: 12.864,
                timestamp: clock.now,
                horizontalAccuracy: 8
            )
        )
        try await journal.finish(at: clock.now)

        let recorder = makeRecorder(
            trailGraphProvider: StubTrailGraphProvider(
                graph: ambiguityGraph()
            )
        )
        await recorder.recoverOpenSession()

        #expect(recorder.phase == .reviewing)
        #expect(recorder.ambiguityReview?.ambiguities.count == 1)
        #expect(try context.fetch(FetchDescriptor<Hike>()).isEmpty)
        #expect(FileManager.default.fileExists(atPath: journal.journalURL.path))
        await recorder.discard()
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
        try await journal.start(
            sessionID: sessionID,
            startedAt: clock.now,
            recordingOptions: .defaults
        )
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
        let recorder = makeRecorder(
            trailGraphProvider: StubTrailGraphProvider(
                graph: .empty,
                cachedGraphDelay: .milliseconds(100)
            )
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
        let hike = try savedHike(from: await firstStop.value)

        #expect(hike.route.count == 2)
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
        clock.advance(by: 720)
        try await journal.append(
            RecordingPoint(
                latitude: 47.63,
                longitude: 12.864,
                timestamp: clock.now,
                horizontalAccuracy: 8
            )
        )
        try await journal.finish(at: clock.now)

        let recorder = makeRecorder(
            trailGraphProvider: StubTrailGraphProvider(
                graph: ambiguityGraph()
            )
        )
        await recorder.recoverOpenSession()

        let hikes = try context.fetch(FetchDescriptor<Hike>())
        #expect(hikes.count == 1)
        #expect(hikes.first?.title == "Already Saved")
        #expect(recorder.phase == .idle)
        #expect(recorder.ambiguityReview == nil)
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
