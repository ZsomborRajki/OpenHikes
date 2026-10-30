//
//  HikeDetailLineTests+Breakdowns.swift
//  OpenHikesTests
//
//  What a hike's screen measures of its line's surfaces and grades is stored
//  on the hike, so a measurement of a line replaced while it was out must
//  not be kept (#1252's review). The screen keys its work on its line's
//  revision, which moves only once the new line has been read, and the old
//  line's answer can land before then. Kept, it stood for the new line: an
//  edit clears both breakdowns, and the new line's own task found them
//  stored and measured nothing.
//
//  Split from `HikeDetailLineTests`, whose body is near its length limit.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import SwiftData
import Synchronization
import Testing

extension HikeDetailLineTests {
    /// A path along the ridge, gravel underfoot and graded the whole way, so
    /// that the ridge measures as surveyed throughout and the ridge moved
    /// half a degree north as surveyed nowhere.
    static let ridgePath: TrailGraph = {
        let nodes = Fixture.ridgeRoute.enumerated().map { index, point in
            TrailGraphNode(id: Int64(index + 1), coordinate: point.clCoordinate)
        }
        let edges = zip(nodes, nodes.dropFirst()).enumerated().map { index, leg in
            TrailGraphEdge(
                id: TrailGraphEdgeID(wayID: 1, segmentIndex: index),
                fromNodeID: leg.0.id,
                toNodeID: leg.1.id,
                lengthMeters: RouteGeometry.distanceMeters(from: leg.0.coordinate, to: leg.1.coordinate),
                sacScale: "hiking",
                surface: "gravel",
                highway: "path"
            )
        }
        return TrailGraph(nodes: nodes, edges: edges)
    }()

    /// What the screen measures of `route` along ``ridgePath``.
    private static func measured(_ route: [RouteCoordinate]) async -> HikeTrailBreakdowns {
        await HikeTrailAnalysis.breakdowns(route: route, provider: StubTrailGraphProvider(graph: ridgePath))
    }

    @Test("a measurement of a line replaced while it was out is not stored for the new line")
    func aReplacedLinesMeasurementIsNotStored() async throws {
        let graph = HeldTrailGraph(Self.ridgePath)
        defer { graph.open() }
        defer { lineFetches.open() }
        // The premise: the ridge is surveyed, and the moved line is not.
        let ridge = await Self.measured(Fixture.ridgeRoute)
        let moved = await Self.measured(Self.movedRoute)
        try #require((ridge.surface?.surveyedFraction ?? 0) > 0.5, "the ridge's surface is surveyed")
        try #require((ridge.difficulty?.surveyedFraction ?? 0) > 0.5, "and so are its grades")
        try #require((moved.surface?.surveyedFraction ?? 1) < 0.5, "the moved line's surface is not")
        try #require((moved.difficulty?.surveyedFraction ?? 1) < 0.5, "nor are its grades")

        let hike = Fixture.hike(in: container.mainContext)
        try await RemoteChangeLog.save(container.mainContext, settling: hike)
        await select(hike)
        let window = try host(hike, withHikesList: true, trailGraphProvider: graph)
        defer { Self.takeDown(window) }
        await settleDelegateHop(until: "the ridge is being measured") { graph.asked == 1 }

        // What *Edit Route* writes: a new line under the same id, its
        // breakdowns cleared, saved at once. Its read is held.
        lineFetches.arm()
        hike.replaceRoute(with: Self.movedRoute)
        hike.distanceMeters = RouteProfile(route: Self.movedRoute).totalDistanceMeters
        hike.surfaceMetersByCategory = [:]
        hike.difficultyMetersByGrade = [:]
        try container.mainContext.save()
        await settleDelegateHop(until: "the new line's read is out") { self.lineFetches.isHolding }

        // The ridge's answer lands while the new line is still being read.
        graph.open()
        await settleDelegateHop(until: "the ridge's graph has been handed back") { graph.answered == 1 }
        await settleDelegateHop()
        lineFetches.open()

        await settleDelegateHop(until: "the screen has built its profile on the new line") {
            Self.isOnMovedRoute(self.highlight.coordinate)
        }
        await settleDelegateHop(until: "the new line's own measurement is stored") {
            (hike.surfaceBreakdown?.surveyedFraction ?? 1) < 0.5
                && (hike.difficultyBreakdown?.surveyedFraction ?? 1) < 0.5
        }
        #expect(graph.asked == 2, "the new line was measured for itself")
    }
}

/// The trail graph a hike's screen measures from, with its first lookup held
/// until the test opens it, so the line it measures can be replaced while the
/// answer is out.
nonisolated private final class HeldTrailGraph: TrailGraphProviding {
    private let graph: TrailGraph
    private let gate = Mutex<(isOpen: Bool, waiting: [CheckedContinuation<Void, Never>])>((false, []))
    private let counts = Mutex((asked: 0, answered: 0))

    init(_ graph: TrailGraph) {
        self.graph = graph
    }

    /// How many lookups have been made, and how many handed the graph back.
    var asked: Int { counts.withLock { $0.asked } }
    var answered: Int { counts.withLock { $0.answered } }

    func region(containing coordinate: CLLocationCoordinate2D) -> TrailGraphRegion? { nil }

    func prefetch(around coordinate: CLLocationCoordinate2D) { /* everything is cached */ }

    func hasCompleteCachedGraph(covering coordinates: [CLLocationCoordinate2D]) -> Bool { true }

    func cachedGraph(covering coordinates: [CLLocationCoordinate2D]) async -> TrailGraph? {
        let isFirst = counts.withLock { counts in
            counts.asked += 1
            return counts.asked == 1
        }
        if isFirst {
            await withCheckedContinuation { continuation in
                let isOpen = gate.withLock { state in
                    if !state.isOpen { state.waiting.append(continuation) }
                    return state.isOpen
                }
                if isOpen { continuation.resume() }
            }
        }
        counts.withLock { $0.answered += 1 }
        return graph
    }

    func open() {
        let waiting = gate.withLock { state in
            state.isOpen = true
            defer { state.waiting = [] }
            return state.waiting
        }
        for continuation in waiting { continuation.resume() }
    }
}
