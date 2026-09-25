//
//  TrailLegRouterTests.swift
//  OpenHikesTests
//
//  Making one leg follow a real path, and the three ways that does not
//  happen.
//
//  The claims worth holding still are the ones a hiker would report as bugs
//  and nobody could reproduce:
//
//  - **A leg near a path follows it**, and the length in the header is the
//    length of what is drawn rather than the distance between the two taps.
//  - **A leg far from any path does not snap to something absurd.** The
//    failure this rules out is the one with no obvious symptom: a point put
//    down in a trackless corrie quietly acquiring a route through the nearest
//    valley, which is a line the hiker never drew and would only discover on
//    the ground.
//  - **A refused fetch leaves a straight leg and says why.** Overpass rate
//    limits have been hit in the field, and drawing must not stop when a
//    volunteer-run API is busy.
//
//  Every one of them goes through a stub provider rather than the network,
//  which is the seam ``TrailGraphProviding`` exists to give — see *Deliberate
//  test seams*.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import Testing

@Suite("Trail leg router")
struct TrailLegRouterTests {
    /// A path running due north along one line of longitude, in four hops, so
    /// every distance in here is a degree of latitude and nothing else.
    private enum Path {
        static let longitude = 12.8317
        static let latitudes = [47.7180, 47.7190, 47.7200, 47.7210, 47.7220]
        /// A parallel line of longitude a long way east of the path — about
        /// 1.5 km at this latitude, comfortably outside the snap radius.
        static let farLongitude = 12.8517
    }

    private static func onPath(_ index: Int) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: Path.latitudes[index], longitude: Path.longitude)
    }

    private static func offPath(_ index: Int) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: Path.latitudes[index], longitude: Path.farLongitude)
    }

    /// The straight line of segments above, as a graph.
    private static func pathGraph() -> TrailGraph {
        let nodes = Path.latitudes.enumerated().map { index, latitude in
            TrailGraphNode(
                id: Int64(index + 1),
                coordinate: CLLocationCoordinate2D(
                    latitude: latitude,
                    longitude: Path.longitude
                )
            )
        }
        let edges = (0..<(nodes.count - 1)).map { index in
            TrailGraphEdge(
                id: TrailGraphEdgeID(wayID: 10, segmentIndex: index),
                fromNodeID: nodes[index].id,
                toNodeID: nodes[index + 1].id,
                lengthMeters: RouteGeometry.distanceMeters(
                    from: nodes[index].coordinate,
                    to: nodes[index + 1].coordinate
                ),
                name: "Ridge Path"
            )
        }
        return TrailGraph(nodes: nodes, edges: edges)
    }

    private static func ends(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D
    ) -> TrailLegEnds {
        TrailLegEnds(
            from: TrailWaypoint(coordinate: start),
            to: TrailWaypoint(coordinate: end)
        )
    }

    private static func router(
        _ provider: any TrailGraphProviding
    ) -> OverpassTrailLegRouter {
        OverpassTrailLegRouter(provider: provider)
    }

    // MARK: Following a path

    /// Two taps a few metres off the line, three segments apart: the answer
    /// runs along the path rather than through the middle of the hillside.
    @Test("a leg between two points on a path follows it")
    func snapsToThePath() async throws {
        let router = Self.router(StubTrailGraphProvider(graph: Self.pathGraph()))
        let ends = Self.ends(from: Self.onPath(0), to: Self.onPath(3))

        let route = try #require(await router.route(ends))

        #expect(route.snap == .snapped)
        #expect(
            route.coordinates.count > 2,
            "a snapped leg is the path's own points, not just its two ends"
        )
        #expect(
            route.coordinates.allSatisfy { point in
                abs(point.longitude - Path.longitude) < 0.0001
            },
            "every point of a leg along one line of longitude is on it"
        )
    }

    /// The figure the header draws and the figure the library keeps. It is
    /// measured along the drawn shape, so a snapped leg reports the path's
    /// length — which for a straight-line fixture is the same as the distance
    /// between the ends, and that equality is the point: nothing is
    /// double-counted by the connectors at either end.
    @Test("a snapped leg is measured along what is drawn")
    func lengthFollowsTheShape() async throws {
        let router = Self.router(StubTrailGraphProvider(graph: Self.pathGraph()))
        let ends = Self.ends(from: Self.onPath(0), to: Self.onPath(3))

        let route = try #require(await router.route(ends))

        #expect(abs(route.distanceMeters - ends.straightDistanceMeters) < 1)
    }

    /// Both taps projecting onto the same segment is its own branch — there
    /// is no node path to walk — and it has to answer with the piece of the
    /// segment between them rather than with nothing.
    @Test("two points on one segment still snap")
    func bothEndsOnOneSegment() async throws {
        let router = Self.router(StubTrailGraphProvider(graph: Self.pathGraph()))
        let ends = Self.ends(from: Self.onPath(0), to: Self.onPath(1))

        let route = try #require(await router.route(ends))

        #expect(route.snap == .snapped)
        #expect(abs(route.distanceMeters - ends.straightDistanceMeters) < 1)
    }

    // MARK: Not following one

    /// The claim with no symptom: a leg drawn where nothing is mapped stays
    /// exactly where it was drawn.
    @Test("a leg far from any path does not snap to something absurd")
    func doesNotSnapFromFarAway() async throws {
        let router = Self.router(StubTrailGraphProvider(graph: Self.pathGraph()))
        let ends = Self.ends(from: Self.offPath(0), to: Self.offPath(3))

        let route = try #require(await router.route(ends))

        #expect(route.snap == .unmapped(.noPathBetween))
        #expect(
            route.coordinates == ends.straightCoordinates,
            "an unroutable leg is the line the hiker drew, unchanged"
        )
        #expect(abs(route.distanceMeters - ends.straightDistanceMeters) < 0.001)
    }

    /// One end on the path and one a kilometre and a half off it is still not
    /// a leg anybody can route: it would have to invent the half that is not
    /// mapped.
    @Test("one end off the map is enough to leave the leg straight")
    func oneEndOffThePath() async throws {
        let router = Self.router(StubTrailGraphProvider(graph: Self.pathGraph()))
        let ends = Self.ends(from: Self.onPath(0), to: Self.offPath(3))

        let route = try #require(await router.route(ends))

        #expect(route.snap == .unmapped(.noPathBetween))
    }

    /// A graph with nothing in it is an answer rather than a failure: it is
    /// what an area nobody has mapped looks like.
    @Test("an empty graph leaves a straight leg and no warning")
    func emptyGraphIsAnAnswer() async throws {
        let router = Self.router(StubTrailGraphProvider(graph: .empty))
        let ends = Self.ends(from: Self.onPath(0), to: Self.onPath(3))

        let route = try #require(await router.route(ends))

        #expect(route.snap == .unmapped(.noPathBetween))
    }

    /// Refused before a single byte is spent, because the corridor for a leg
    /// this long is several z12 tiles and the hiker's answer is to put a
    /// point in the middle.
    @Test("a leg longer than the ceiling is not asked about at all")
    func tooFarApartIsNotAsked() async throws {
        let provider = StubTrailGraphProvider(graph: Self.pathGraph())
        let router = Self.router(provider)
        let start = Self.onPath(0)
        let ends = Self.ends(
            from: start,
            to: CLLocationCoordinate2D(
                latitude: start.latitude + 1,
                longitude: start.longitude
            )
        )

        let route = try #require(await router.route(ends))

        #expect(route.snap == .unmapped(.tooFarApart))
        #expect(
            await provider.prefetches().isEmpty,
            "nothing should be downloaded for a leg that is refused on sight"
        )
    }

    // MARK: A refusal

    /// The field case. A busy Overpass leaves the line drawn and says so, and
    /// the sentence is the curated work's rather than a second spelling of
    /// it — see ``CuratedTrailOutage``.
    @Test("a refused fetch leaves a straight leg and reports the refusal")
    func refusalIsReported() async throws {
        let router = Self.router(
            RefusingTrailGraphProvider(error: .server(statusCode: 504))
        )
        let ends = Self.ends(from: Self.onPath(0), to: Self.onPath(3))

        let route = try #require(await router.route(ends))

        #expect(route.snap == .refused(.busy), "a 504 is a queue, not an outage")
        #expect(route.coordinates == ends.straightCoordinates)
    }

    @Test("a rate limit is reported with what is left of the wait")
    func rateLimitCarriesItsWait() async throws {
        let router = Self.router(
            RefusingTrailGraphProvider(error: .rateLimited(retryAfter: 42))
        )
        let ends = Self.ends(from: Self.onPath(0), to: Self.onPath(3))

        let route = try #require(await router.route(ends))

        #expect(route.snap == .refused(.rateLimited(retryAfter: 42)))
    }

    /// A refusal must be askable again, which is the whole of what *Retry*
    /// does. Caching one would make the button a no-op.
    @Test("a refusal is not remembered, so asking again really asks")
    func refusalsAreNotCached() async {
        let provider = RefusingTrailGraphProvider(error: .server(statusCode: 504))
        let router = Self.router(provider)
        let ends = Self.ends(from: Self.onPath(0), to: Self.onPath(3))

        _ = await router.route(ends)
        _ = await router.route(ends)

        #expect(await provider.attemptCount() == 2)
    }

    /// And a settled answer is remembered, which is what makes toggling
    /// snapping off and on again free — and what a reorder leans on, since it
    /// moves rows without moving anything on the ground.
    @Test("a settled answer is remembered and costs nothing to ask twice")
    func settledAnswersAreCached() async throws {
        let provider = CountingTrailGraphProvider(graph: Self.pathGraph())
        let router = Self.router(provider)
        let ends = Self.ends(from: Self.onPath(0), to: Self.onPath(3))

        let first = try #require(await router.route(ends))
        let second = try #require(await router.route(ends))

        #expect(first == second)
        #expect(await provider.fetchCount() == 1)
    }
}
