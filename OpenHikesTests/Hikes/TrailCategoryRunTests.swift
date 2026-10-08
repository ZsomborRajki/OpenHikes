//
//  TrailCategoryRunTests.swift
//  OpenHikesTests
//
//  `TrailBreakdownAnalyzer.runs`, which is the breakdown kept in route order
//  instead of totalled — what the map colours a line by. The breakdown's own
//  arithmetic is `TrailSurfaceAnalyzerTests`'; what is asserted here is the
//  geometry the totals throw away, and that the two never disagree about how
//  much of a route is in which grade.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import RealModule
import Testing

@Suite("Trail category runs")
struct TrailCategoryRunTests {
    private static let baseLongitude = 12.8600
    private static let south = 47.6300
    private static let junction = 47.6310
    private static let north = 47.6320

    /// Two ways meeting end to end: the southern half a plain hiking path,
    /// the northern half alpine.
    private static func splitGraph() -> TrailGraph {
        let nodes = [
            TrailGraphNode(id: 1, coordinate: CLLocationCoordinate2D(latitude: south, longitude: baseLongitude)),
            TrailGraphNode(id: 2, coordinate: CLLocationCoordinate2D(latitude: junction, longitude: baseLongitude)),
            TrailGraphNode(id: 3, coordinate: CLLocationCoordinate2D(latitude: north, longitude: baseLongitude)),
        ]
        let edges = [
            edge(way: 10, from: nodes[0], to: nodes[1], sacScale: "hiking"),
            edge(way: 11, from: nodes[1], to: nodes[2], sacScale: "alpine_hiking"),
        ]
        return TrailGraph(nodes: nodes, edges: edges)
    }

    private static func edge(
        way: Int64,
        from: TrailGraphNode,
        to: TrailGraphNode,
        sacScale: String
    ) -> TrailGraphEdge {
        TrailGraphEdge(
            id: TrailGraphEdgeID(wayID: way, segmentIndex: 0),
            fromNodeID: from.id,
            toNodeID: to.id,
            lengthMeters: RouteGeometry.distanceMeters(from: from.coordinate, to: to.coordinate),
            sacScale: sacScale
        )
    }

    private static func route(_ latitudes: [Double], longitude: Double = baseLongitude) -> [RouteCoordinate] {
        latitudes.map { RouteCoordinate(latitude: $0, longitude: longitude) }
    }

    @Test("a route over two graded ways is two runs, in route order, meeting at the junction")
    func splitsAtTheJunction() async throws {
        let walked = Self.route((0...4).map { Self.south + Double($0) * 0.0005 })

        let runs = try await TrailBreakdownAnalyzer.runs(
            of: TrailDifficulty.self,
            route: walked,
            graph: Self.splitGraph()
        )

        #expect(runs.map(\.category) == [.hiking, .alpineHiking])
        let first = try #require(runs.first?.coordinates)
        let last = try #require(runs.last?.coordinates)
        #expect(first.first?.latitude == walked.first?.latitude)
        #expect(last.last?.latitude == walked.last?.latitude)
        // Drawn end to end they leave no gap: the second starts exactly
        // where the first ends, and that is the junction to within a sample.
        let boundary = try #require(first.last)
        #expect(last.first?.latitude == boundary.latitude)
        let offJunction = RouteGeometry.distanceMeters(
            from: boundary,
            to: CLLocationCoordinate2D(latitude: Self.junction, longitude: Self.baseLongitude)
        )
        #expect(offJunction <= TrailBreakdownAnalyzer.samplingStepMeters)
    }

    /// The map and the Difficulty bar are read with one legend, so a stretch
    /// drawn red has to be the red share of the bar — both come out of one
    /// walk, and this is what would notice if they ever stopped doing so.
    @Test("the runs cover exactly the distance the breakdown attributes to each grade")
    func runsAgreeWithTheBreakdown() async throws {
        // Deliberately not on the junction: the boundary then falls inside a
        // route segment, which is the case where a run is cut mid-segment.
        let walked = Self.route([Self.south, 47.63073, 47.63142, Self.north])
        let graph = Self.splitGraph()

        let runs = try await TrailBreakdownAnalyzer.runs(of: TrailDifficulty.self, route: walked, graph: graph)
        let breakdown = try await TrailBreakdownAnalyzer.breakdown(
            of: TrailDifficulty.self,
            route: walked,
            graph: graph
        )

        var drawn: [TrailDifficulty: Double] = [:]
        for run in runs {
            drawn[run.category, default: 0] += RouteGeometry.lengthMeters(of: run.coordinates)
        }
        #expect(Set(drawn.keys) == Set(breakdown.shares.map(\.category)))
        for share in breakdown.shares {
            #expect(drawn[share.category, default: 0].isApproximatelyEqual(to: share.meters, absoluteTolerance: 0.5))
        }
    }

    /// Twenty-metre samples along a straight hundred metres are five
    /// collinear points, all drawing the line its two ends already draw — and
    /// on a real route that is thousands of them.
    @Test("a run along one straight segment keeps its two ends and nothing between")
    func collinearSamplesAddNoPoints() async throws {
        let walked = Self.route([Self.south, 47.63095])

        let runs = try await TrailBreakdownAnalyzer.runs(
            of: TrailDifficulty.self,
            route: walked,
            graph: Self.splitGraph()
        )

        let run = try #require(runs.first)
        #expect(runs.count == 1)
        #expect(run.coordinates.count == 2)
    }

    @Test("a stretch with no way beneath it is its own unmapped run")
    func offTheGraphIsUnmapped() async throws {
        // Out along the path, a kilometre east where nothing is mapped, and
        // back onto it.
        let east = Self.baseLongitude + 1000 / 74_933.0
        let walked = [
            RouteCoordinate(latitude: Self.south, longitude: Self.baseLongitude),
            RouteCoordinate(latitude: 47.6305, longitude: Self.baseLongitude),
            RouteCoordinate(latitude: 47.6305, longitude: east),
            RouteCoordinate(latitude: 47.6306, longitude: east),
            RouteCoordinate(latitude: 47.6306, longitude: Self.baseLongitude),
            RouteCoordinate(latitude: 47.6308, longitude: Self.baseLongitude),
        ]

        let runs = try await TrailBreakdownAnalyzer.runs(
            of: TrailDifficulty.self,
            route: walked,
            graph: Self.splitGraph()
        )

        #expect(runs.map(\.category) == [.hiking, .unmapped, .hiking])
    }

    @Test("a route of one point has no runs")
    func aDegenerateRouteHasNoRuns() async throws {
        let runs = try await TrailBreakdownAnalyzer.runs(
            of: TrailDifficulty.self,
            route: Self.route([Self.south]),
            graph: Self.splitGraph()
        )

        #expect(runs.isEmpty)
    }
}
