//
//  HikeRecorderTests.swift
//  OpenHikesTests
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesShared
import SwiftData
import Testing

final class StubRecordingLocationSource: RecordingLocationSource {
    var authorization: RecordingLocationAuthorization = .authorized
    var hasFullAccuracy = true
    weak var delegateObject: AnyObject?

    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var releaseOrphanedBackgroundActivityCount = 0
    private(set) var authorizationRequests = 0
    private(set) var fullAccuracyRequests = 0
    /// Every profile the recorder pushed, in order, so a test can assert the
    /// GPS was actually reconfigured rather than that the policy merely
    /// returned a different value.
    private(set) var appliedProfiles: [RecordingEnergyProfile] = []

    var currentProfile: RecordingEnergyProfile? { appliedProfiles.last }

    var sourceDelegate: CLLocationManagerDelegate? {
        get { delegateObject as? CLLocationManagerDelegate }
        set { delegateObject = newValue }
    }

    func requestWhenInUseAuthorization() {
        authorizationRequests += 1
    }

    func requestTemporaryFullAccuracy() {
        fullAccuracyRequests += 1
    }

    func startRecordingUpdates(profile: RecordingEnergyProfile) {
        startCount += 1
        apply(profile)
    }

    func apply(_ profile: RecordingEnergyProfile) {
        guard profile != appliedProfiles.last else { return }
        appliedProfiles.append(profile)
    }

    func stopRecordingUpdates() {
        stopCount += 1
    }

    func releaseOrphanedBackgroundActivity() {
        releaseOrphanedBackgroundActivityCount += 1
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

final class StubRecordingElevationSource: RecordingElevationSource {
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

final class StubRecordingMotionSource: RecordingMotionSource {
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

struct InjectedPersistenceError: LocalizedError {
    var errorDescription: String? {
        "Injected persistence failure."
    }
}

final class ScriptedModelContextSaver {
    private var failedSaveNumbers: Set<Int>
    private(set) var saveCount = 0

    init(failedSaveNumbers: Set<Int>) {
        self.failedSaveNumbers = failedSaveNumbers
    }

    func save(_ context: ModelContext) throws {
        saveCount += 1
        if failedSaveNumbers.remove(saveCount) != nil { throw InjectedPersistenceError() }
        try context.save()
    }
}

actor StubRecordingSharedStateStore:
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

actor BlockingClearRecordingSharedStateStore:
    RecordingSharedStateStoring {
    private var clearStarted = false
    private var clearContinuation: CheckedContinuation<Void, Never>?

    func save(
        _ snapshot: SharedRecordingSnapshot,
        reloadWidget: Bool
    ) { /* no-op stub */ }

    func clear(sessionID: UUID?) async {
        clearStarted = true
        await withCheckedContinuation { continuation in
            clearContinuation = continuation
        }
    }

    func pendingFixes(
        for sessionID: UUID
    ) -> [SharedRecordingFix] {
        []
    }

    func removePendingFixes(ids: Set<UUID>) { /* no-op stub */ }

    func waitForClearToStart() async {
        while !clearStarted {
            await Task.yield()
        }
    }

    func releaseClear() {
        clearContinuation?.resume()
        clearContinuation = nil
    }
}

@Suite("Hike recorder")
final class HikeRecorderTests {
    let container: ModelContainer
    let context: ModelContext
    let source = StubRecordingLocationSource()
    let clock = TestClock()
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "recording-sandbox-\(UUID().uuidString)",
            isDirectory: true
        )
    // periphery:ignore - the strong reference that keeps the recorder alive
    // for the length of the test; never read back.
    var recorder: HikeRecorder?

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

    func makeRecorder(
        elevationSource: (any RecordingElevationSource)? = nil,
        motionSource: (any RecordingMotionSource)? = nil,
        trailGraphProvider: (any TrailGraphProviding)? = nil,
        trailGraphRetryPolicy: TrailGraphPrefetchRetryPolicy = .standard,
        trailGraphRetryJitter: @escaping @Sendable () -> Double = {
            Double.random(in: 0...1)
        },
        trailGraphNetworkDecision: @escaping @Sendable (
            TileFetchPurpose
        ) -> TileNetworkDecision = { _ in .allowed },
        sharedStateStore: (any RecordingSharedStateStoring)? = nil,
        automaticallyRecovers: Bool = false,
        powerMonitor: PowerStateMonitor? = nil,
        saveModelContext: @escaping (ModelContext) throws -> Void = { context in
            try context.save()
        },
        configureDefaults: (UserDefaults) -> Void = { _ in /* no-op */ }
    ) -> HikeRecorder {
        let defaults = UserDefaults(
            suiteName: "hike-recorder-settings-\(UUID().uuidString)"
        ) ?? UserDefaults.standard
        configureDefaults(defaults)
        let instance = HikeRecorder(
            container: container,
            saveModelContext: saveModelContext,
            source: source,
            elevationSource: elevationSource,
            motionSource: motionSource,
            trailGraphProvider: trailGraphProvider,
            trailGraphRetryPolicy: trailGraphRetryPolicy,
            trailGraphRetryJitter: trailGraphRetryJitter,
            trailGraphNetworkDecision: trailGraphNetworkDecision,
            defaults: defaults,
            powerMonitor: powerMonitor
                // Never the default one in a test: it registers for
                // process-wide notifications, and a suite that ran on a laptop
                // in Low Power Mode would otherwise assert against the
                // machine's battery rather than against the policy.
                ?? PowerStateMonitor(
                    read: { PowerState() },
                    observesNotifications: false
                ),
            sharedStateStore: sharedStateStore,
            journalDirectory: directory,
            clock: clock.read,
            journalFlushDelay: .zero,
            automaticallyRecovers: automaticallyRecovers
        )
        recorder = instance
        return instance
    }

    func matchedPathGraph() -> TrailGraph {
        let from = TrailGraphNode(
            id: 201,
            coordinate: CLLocationCoordinate2D(latitude: 47.6298, longitude: 12.8599)
        )
        let to = TrailGraphNode(
            id: 202,
            coordinate: CLLocationCoordinate2D(latitude: 47.6305, longitude: 12.8599)
        )
        return TrailGraph(
            nodes: [from, to],
            edges: [
                TrailGraphEdge(
                    id: TrailGraphEdgeID(wayID: 201, segmentIndex: 0),
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
                ),
            ]
        )
    }

    func liveMatchingGraph() -> TrailGraph {
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
                ),
            ]
        )
    }

    func ambiguityGraph() -> TrailGraph {
        let definitions: [(Int64, Double, Double)] = [
            (1, 47.6300, 12.8600),
            (2, 47.6302, 12.8600),
            (3, 47.6340, 12.8600),
            (4, 47.6340, 12.8640),
            (5, 47.6302, 12.8640),
            (6, 47.6300, 12.8640),
            (7, 47.6260, 12.8600),
            (8, 47.6260, 12.8640),
        ]
        let nodes = definitions.map { definition in
            TrailGraphNode(
                id: definition.0,
                coordinate: CLLocationCoordinate2D(
                    latitude: definition.1,
                    longitude: definition.2
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
            (13, [5, 6], "Fork Trail"),
        ]
        var edges: [TrailGraphEdge] = []
        for way in ways {
            for index in 0..<(way.1.count - 1) {
                guard let from = byID[way.1[index]], let to = byID[way.1[index + 1]] else { continue }
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

    func savedHike(
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

    func fix(
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

    func acceleratedLocations(
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

}
