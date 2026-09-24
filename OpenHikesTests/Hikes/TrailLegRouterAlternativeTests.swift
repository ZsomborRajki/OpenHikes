//
//  TrailLegRouterAlternativeTests.swift
//  OpenHikesTests
//
//  The other ways a hiking leg could go, offered the way Apple Maps offers
//  them — see ``OverpassTrailLegRouter/alternatives(to:from:to:using:)``.
//
//  The graph is a loop: a straight path north, and a second path that leaves
//  it at the bottom, runs parallel a couple of hundred metres east and rejoins
//  it at the top. That is the shape an alternative exists for — the other side
//  of a lake — and the one thing a suite can build that has exactly one.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import Testing

@Suite("Trail leg router alternatives")
struct TrailLegRouterAlternativeTests {
    private enum Loop {
        static let west = 12.8317
        static let latitudes = [47.7180, 47.7190, 47.7200, 47.7210, 47.7220]
        /// Near enough that the loop is a real choice, well under half as long
        /// again as the straight path.
        static let nearEast = 12.8337
        /// Far enough that going round is more than half as long again.
        static let farEast = 12.8417
    }

    private static func node(_ id: Int64, _ latitude: Double, _ longitude: Double) -> TrailGraphNode {
        TrailGraphNode(id: id, coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude))
    }

    private static func edge(
        _ way: Int64,
        _ index: Int,
        _ from: TrailGraphNode,
        _ to: TrailGraphNode
    ) -> TrailGraphEdge {
        TrailGraphEdge(
            id: TrailGraphEdgeID(wayID: way, segmentIndex: index),
            fromNodeID: from.id,
            toNodeID: to.id,
            lengthMeters: RouteGeometry.distanceMeters(from: from.coordinate, to: to.coordinate),
            name: nil
        )
    }

    /// The straight path, and — unless `east` is `nil` — the loop beside it.
    private static func graph(loopingAt east: Double?) -> TrailGraph {
        let path = Loop.latitudes.enumerated().map { node(Int64($0.offset + 1), $0.element, Loop.west) }
        var nodes = path
        var edges = (0..<(path.count - 1)).map { edge(1, $0, path[$0], path[$0 + 1]) }
        if let east {
            let loop = Loop.latitudes.dropFirst().dropLast().enumerated().map { index, latitude in
                node(Int64(100 + index), latitude, east)
            }
            let round = [path[0]] + loop + [path[path.count - 1]]
            nodes += loop
            edges += (0..<(round.count - 1)).map { edge(2, $0, round[$0], round[$0 + 1]) }
        }
        return TrailGraph(nodes: nodes, edges: edges)
    }

    private static let ends = TrailLegEnds(
        start: RouteCoordinate(latitude: Loop.latitudes[0], longitude: Loop.west),
        end: RouteCoordinate(latitude: Loop.latitudes[Loop.latitudes.count - 1], longitude: Loop.west)
    )

    private static func route(over graph: TrailGraph) async throws -> TrailLegRoute {
        let router = OverpassTrailLegRouter(provider: StubTrailGraphProvider(graph: graph))
        return try #require(await router.route(ends))
    }

    @Test("the other side of a loop is offered beside the straight path")
    func aLoopIsOffered() async throws {
        let route = try await Self.route(over: Self.graph(loopingAt: Loop.nearEast))

        #expect(route.snap == .snapped)
        #expect(route.coordinates.allSatisfy { abs($0.longitude - Loop.west) < 0.0001 }, "the shorter way is drawn")
        #expect(route.alternatives.count == 1)
        let alternative = try #require(route.alternatives.first)
        #expect(alternative.coordinates.contains { abs($0.longitude - Loop.nearEast) < 0.0001 })
        #expect(alternative.distanceMeters > route.distanceMeters)
        #expect(alternative.coordinates.first == Self.ends.start, "it runs from the stop itself")
        #expect(alternative.coordinates.last == Self.ends.end)
    }

    @Test("a single path offers nothing beside itself")
    func aSinglePathOffersNothing() async throws {
        let route = try await Self.route(over: Self.graph(loopingAt: nil))

        #expect(route.snap == .snapped)
        #expect(route.alternatives.isEmpty)
    }

    /// Twice as long is a different walk, not a choice about this one.
    @Test("a detour more than half as long again is not offered")
    func aLongDetourIsNotOffered() async throws {
        let route = try await Self.route(over: Self.graph(loopingAt: Loop.farEast))

        #expect(route.alternatives.isEmpty)
    }
}
