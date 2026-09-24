//
//  TrailLegRouterRoadTests.swift
//  OpenHikesTests
//
//  A drawn hiking leg through a village: the roads that join one path to the
//  next, and Apple Maps behind the graph when even they do not.
//
//  The field report behind it: two points on either side of Schönau am
//  Königssee, a footpath between them that Apple Maps walks without trouble,
//  and a straight line from the maker — because the path was mapped partly
//  as `service` segments and the trail graph had dropped every one. The
//  claims held still here are the ones that report rests on:
//
//  - **A road joins two trails** for a drawn leg, and **never** for a
//    recording, whose index is still trails only.
//  - **A path is still preferred** where it is not much longer than the road.
//  - **A leg the graph cannot join asks Apple Maps**, is timed at the hiking
//    pace, and stays unmapped when Apple has nothing either.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import Testing

@Suite("Trail leg router over roads")
struct TrailLegRouterRoadTests {
    /// Everything runs north up one line of longitude; each step of latitude
    /// here is about 111 m.
    private static let longitude = 12.8
    /// East of the line: about 415 m at this latitude, which makes the detour
    /// through it about 1.3 times the straight road it bypasses.
    nonisolated private static let detourLongitude = 12.8055

    private static func point(_ latitude: Double, _ longitude: Double = longitude) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// A graph from nodes and `(from, to, highway)` edges, each edge its own
    /// way.
    private static func graph(
        nodes: [Int64: CLLocationCoordinate2D],
        edges: [(Int64, Int64, String)]
    ) -> TrailGraph {
        TrailGraph(
            nodes: nodes.map { TrailGraphNode(id: $0.key, coordinate: $0.value) },
            edges: edges.enumerated().map { index, edge in
                TrailGraphEdge(
                    id: TrailGraphEdgeID(wayID: Int64(index + 1), segmentIndex: 0),
                    fromNodeID: edge.0,
                    toNodeID: edge.1,
                    lengthMeters: RouteGeometry.distanceMeters(
                        from: nodes[edge.0] ?? point(0),
                        to: nodes[edge.1] ?? point(0)
                    ),
                    highway: edge.2
                )
            }
        )
    }

    /// A path, a residential street, and another path, end to end — the
    /// shape of two footpaths either side of a village lane.
    private static let joinedByRoad = graph(
        nodes: [
            1: point(47.700), 2: point(47.703), 3: point(47.712), 4: point(47.715),
        ],
        edges: [(1, 2, "path"), (2, 3, "residential"), (3, 4, "footway")]
    )

    private static func ends(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D
    ) -> TrailLegEnds {
        TrailLegEnds(from: TrailWaypoint(coordinate: start), to: TrailWaypoint(coordinate: end))
    }

    /// Apple Maps' walking router with its answer scripted, and a count of
    /// how often it was asked.
    private static func directions(
        _ calculate: @escaping @Sendable (TrailLegEnds) async throws -> [DirectionsTrailLegRouter.Answer],
        counting calls: CallCount
    ) -> DirectionsTrailLegRouter {
        DirectionsTrailLegRouter(mode: .walking) { ends, _ in
            await calls.bump()
            return try await calculate(ends)
        }
    }

    /// A line Apple might draw between `ends`, bowed east so it cannot be
    /// mistaken for the straight fallback.
    nonisolated private static func appleLine(_ ends: TrailLegEnds) -> [DirectionsTrailLegRouter.Answer] {
        let middle = RouteCoordinate(
            latitude: (ends.start.latitude + ends.end.latitude) / 2,
            longitude: detourLongitude
        )
        return [
            DirectionsTrailLegRouter.Answer(
                coordinates: [ends.start, middle, ends.end],
                travelTime: 600
            ),
        ]
    }

    // MARK: Roads in the graph

    @Test("a road joins two trails for a drawn leg")
    func roadJoinsTrails() async throws {
        let router = OverpassTrailLegRouter(provider: StubTrailGraphProvider(graph: Self.joinedByRoad))

        let route = try #require(await router.route(Self.ends(from: Self.point(47.700), to: Self.point(47.715))))

        #expect(route.snap == .snapped)
        #expect(route.coordinates.count > 2, "the leg follows the ways, not the straight line")
    }

    /// The other half of the same claim: a recording's index is built the
    /// way it always was, so a trace in a village is never matched onto the
    /// lane beside its path.
    @Test("a recording's index leaves the roads out")
    func trailsIndexHasNoRoads() {
        let trails = TrailMatcherGraphIndex(graph: Self.joinedByRoad)
        let walking = TrailMatcherGraphIndex(graph: Self.joinedByRoad, network: .walking)

        #expect(trails.edges.map(\.highway) == ["path", "footway"])
        #expect(trails.nodes.count == 4, "the road's ends are the trails' ends here")
        #expect(walking.edges.count == 3)
        #expect(walking.edgeWeights == [1, TrailGraphHighway.walkingCost(of: "residential"), 1])
    }

    /// A straight residential street against a path about 30% longer round
    /// the side: residential costs half as much again as a path, so the
    /// path wins. The spurs keep either tap well clear of the road, so the
    /// choice is Dijkstra's and not the snap's.
    @Test("a path a little longer than the road is still preferred")
    func prefersPathOverRoad() async throws {
        let graph = Self.graph(
            nodes: [
                0: Self.point(47.6960), 1: Self.point(47.7000),
                2: Self.point(47.7090), 3: Self.point(47.7045, Self.detourLongitude),
                4: Self.point(47.7130),
            ],
            edges: [
                (0, 1, "path"), (1, 2, "residential"), (1, 3, "path"), (3, 2, "path"), (2, 4, "path"),
            ]
        )
        let router = OverpassTrailLegRouter(provider: StubTrailGraphProvider(graph: graph))

        let route = try #require(await router.route(Self.ends(from: Self.point(47.6960), to: Self.point(47.7130))))

        #expect(route.snap == .snapped)
        #expect(
            route.coordinates.contains { $0.longitude > Self.longitude + 0.005 },
            "the leg goes round by the path"
        )
    }

    // MARK: Apple Maps behind the graph

    @Test("a leg the graph cannot join follows Apple Maps at the hiking pace")
    func fallsBackToAppleMaps() async throws {
        let calls = CallCount()
        let router = OverpassTrailLegRouter(
            provider: StubTrailGraphProvider(graph: .empty),
            fallback: Self.directions({ Self.appleLine($0) }, counting: calls)
        )
        let ends = Self.ends(from: Self.point(47.700), to: Self.point(47.715))

        let route = try #require(await router.route(ends))
        let again = try #require(await router.route(ends))

        #expect(route.snap == .snapped)
        #expect(route.coordinates.contains { $0.longitude == Self.detourLongitude })
        #expect(route.travelTime == nil, "timed at the hiking pace, not Apple's walking one")
        #expect(again == route)
        #expect(await calls.value == 1, "a settled answer is cached")
    }

    @Test("a leg Apple Maps cannot route either stays unmapped")
    func appleHasNothingEither() async throws {
        let calls = CallCount()
        let router = OverpassTrailLegRouter(
            provider: StubTrailGraphProvider(graph: .empty),
            fallback: Self.directions({ _ in [] }, counting: calls)
        )

        let route = try #require(await router.route(Self.ends(from: Self.point(47.700), to: Self.point(47.715))))

        #expect(route.snap == .unmapped(.noPathBetween))
        #expect(route.coordinates.count == 2)
    }

    /// Overpass refusing is exactly when a hiker must not be stopped: Apple's
    /// line is drawn, and the refusal's *Retry* is not needed.
    @Test("a refused graph still follows Apple Maps")
    func refusalFallsBack() async throws {
        let calls = CallCount()
        let router = OverpassTrailLegRouter(
            provider: RefusingTrailGraphProvider(error: .server(statusCode: 504)),
            fallback: Self.directions({ Self.appleLine($0) }, counting: calls)
        )

        let route = try #require(await router.route(Self.ends(from: Self.point(47.700), to: Self.point(47.715))))

        #expect(route.snap == .snapped)
    }

    /// An Apple failure that could clear — no signal, a throttle — must not
    /// be remembered as *no path here*, or the leg would never ask again.
    @Test("an Apple failure is not cached")
    func appleFailureIsAskedAgain() async throws {
        let calls = CallCount()
        let router = OverpassTrailLegRouter(
            provider: StubTrailGraphProvider(graph: .empty),
            fallback: Self.directions({ _ in throw URLError(.timedOut) }, counting: calls)
        )
        let ends = Self.ends(from: Self.point(47.700), to: Self.point(47.715))

        let route = try #require(await router.route(ends))
        _ = await router.route(ends)

        #expect(route.snap == .unmapped(.noPathBetween))
        #expect(await calls.value == 2)
    }
}

/// How many times a scripted closure ran.
private actor CallCount {
    private(set) var value = 0

    func bump() { value += 1 }
}
