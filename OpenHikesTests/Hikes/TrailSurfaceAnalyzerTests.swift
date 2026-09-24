//
//  TrailSurfaceAnalyzerTests.swift
//  OpenHikesTests
//
//  "Trail surface analysis", split out of TrailSurfaceTests.swift so that a
//  file declares one @Suite. That file's header still holds the context the
//  two share.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import Testing

nonisolated private let metersPerDegreeLongitude = 74_933.0
nonisolated private let metersPerDegreeLatitude = 111_195.0

nonisolated private func longitude(_ base: Double, eastMeters: Double) -> Double {
    base + eastMeters / metersPerDegreeLongitude
}

nonisolated private struct WayFixture {
    let id: Int64
    let nodeIDs: [Int64]
    var surface: String?
    var tracktype: String?
}

nonisolated private func makeGraph(
    nodes: [(id: Int64, latitude: Double, longitude: Double)],
    ways: [WayFixture]
) -> TrailGraph {
    let graphNodes = nodes.map { node in
        TrailGraphNode(
            id: node.id,
            coordinate: CLLocationCoordinate2D(
                latitude: node.latitude,
                longitude: node.longitude
            )
        )
    }
    let byID = Dictionary(uniqueKeysWithValues: graphNodes.map { ($0.id, $0) })
    var edges: [TrailGraphEdge] = []
    for way in ways {
        for index in 0..<(way.nodeIDs.count - 1) {
            guard let from = byID[way.nodeIDs[index]],
                  let to = byID[way.nodeIDs[index + 1]] else { continue }
            edges.append(
                TrailGraphEdge(
                    id: TrailGraphEdgeID(wayID: way.id, segmentIndex: index),
                    fromNodeID: from.id,
                    toNodeID: to.id,
                    lengthMeters: RouteGeometry.distanceMeters(
                        from: from.coordinate,
                        to: to.coordinate
                    ),
                    surface: way.surface,
                    tracktype: way.tracktype
                )
            )
        }
    }
    return TrailGraph(nodes: graphNodes, edges: edges)
}

nonisolated private func route(
    _ points: [(latitude: Double, longitude: Double)]
) -> [RouteCoordinate] {
    points.map { point in
        RouteCoordinate(latitude: point.latitude, longitude: point.longitude)
    }
}

@Suite("Trail surface analysis")
struct TrailSurfaceAnalyzerTests {
    private static let baseLongitude = 12.8600

    /// Two ways meeting end to end, the southern half gravel and the northern
    /// half asphalt.
    private func splitGraph() -> TrailGraph {
        makeGraph(
            nodes: [
                (1, 47.6300, Self.baseLongitude),
                (2, 47.6310, Self.baseLongitude),
                (3, 47.6320, Self.baseLongitude),
            ],
            ways: [
                WayFixture(id: 10, nodeIDs: [1, 2], surface: "gravel"),
                WayFixture(id: 11, nodeIDs: [2, 3], surface: "asphalt"),
            ]
        )
    }

    @Test("a route over two differently surfaced ways splits between them")
    func splitsBetweenTwoWays() async throws {
        // Walked end to end with the junction on a route point, so the two
        // ways contribute exactly the same distance. `breakdown` is
        // `@concurrent` and asserts it is off the main thread, so awaiting it
        // here is also the check that it stays there.
        let walked = route(
            (0...4).map { step in
                (47.6300 + Double(step) * 0.0005, Self.baseLongitude)
            }
        )

        let breakdown = try await TrailBreakdownAnalyzer.breakdown(
            of: TrailSurface.self,
            route: walked,
            graph: splitGraph()
        )

        #expect(
            breakdown.shares
                .map(\.category)
                .sorted { $0.displayOrder < $1.displayOrder } == [.paved, .gravel]
        )
        #expect(
            abs(breakdown.meters(for: .gravel) - breakdown.meters(for: .paved)) < 1
        )
        for share in breakdown.shares {
            #expect(abs(share.fraction - 0.5) < 0.02)
        }
        #expect(abs(breakdown.surveyedFraction - 1) < 1e-9)
    }

    @Test("distance with no way beneath it is unmapped, not snapped")
    func reportsUnmappedDistance() async throws {
        // Half a kilometre east of the graph — far outside the tolerance, and
        // far enough that no projection could be mistaken for a match.
        let east = longitude(Self.baseLongitude, eastMeters: 500)
        let walked = route([
            (47.6300, east),
            (47.6310, east),
            (47.6320, east),
        ])

        let breakdown = try await TrailBreakdownAnalyzer.breakdown(
            of: TrailSurface.self,
            route: walked,
            graph: splitGraph()
        )

        #expect(breakdown.shares.map(\.category) == [.unmapped])
        #expect(breakdown.surveyedFraction == 0)
    }

    @Test("an untagged way still reports what its tracktype implies")
    func usesTracktypeForAnUntaggedWay() async throws {
        let graph = makeGraph(
            nodes: [
                (1, 47.6300, Self.baseLongitude),
                (2, 47.6320, Self.baseLongitude),
            ],
            ways: [
                WayFixture(id: 10, nodeIDs: [1, 2], surface: nil, tracktype: "grade2"),
            ]
        )
        let walked = route([
            (47.6302, Self.baseLongitude),
            (47.6318, Self.baseLongitude),
        ])

        let breakdown = try await TrailBreakdownAnalyzer.breakdown(
            of: TrailSurface.self,
            route: walked,
            graph: graph
        )

        #expect(breakdown.shares.map(\.category) == [.gravel])
    }

    @Test("a mapped way with no surface tagging reports as unknown")
    func reportsUntaggedWayAsUnknown() async throws {
        let graph = makeGraph(
            nodes: [
                (1, 47.6300, Self.baseLongitude),
                (2, 47.6320, Self.baseLongitude),
            ],
            ways: [WayFixture(id: 10, nodeIDs: [1, 2])]
        )
        let walked = route([
            (47.6302, Self.baseLongitude),
            (47.6318, Self.baseLongitude),
        ])

        let breakdown = try await TrailBreakdownAnalyzer.breakdown(
            of: TrailSurface.self,
            route: walked,
            graph: graph
        )

        #expect(breakdown.shares.map(\.category) == [.unknown])
        #expect(breakdown.surveyedFraction == 0)
    }

    @Test("a walk stays on its own way when a parallel one is barely closer")
    func prefersTheWayAlreadyBeingWalked() async throws {
        // A gravel path with an asphalt service road twelve metres to the
        // east. The walk starts unambiguously on the path, then runs seven
        // metres east of it — five metres from the road. Judged fix by fix the
        // road wins that stretch outright; judged as a walk, nobody stepped
        // across a five-metre gap and back.
        let roadLongitude = longitude(Self.baseLongitude, eastMeters: 12)
        let driftLongitude = longitude(Self.baseLongitude, eastMeters: 7)
        let graph = makeGraph(
            nodes: [
                (1, 47.6300, Self.baseLongitude),
                (2, 47.6325, Self.baseLongitude),
                (3, 47.6300, roadLongitude),
                (4, 47.6325, roadLongitude),
            ],
            ways: [
                WayFixture(id: 10, nodeIDs: [1, 2], surface: "gravel"),
                WayFixture(id: 11, nodeIDs: [3, 4], surface: "asphalt"),
            ]
        )
        let walked = route([
            (47.6300, Self.baseLongitude),
            (47.6305, Self.baseLongitude),
            (47.6310, driftLongitude),
            (47.6320, driftLongitude),
        ])

        let breakdown = try await TrailBreakdownAnalyzer.breakdown(
            of: TrailSurface.self,
            route: walked,
            graph: graph
        )

        #expect(breakdown.shares.map(\.category) == [.gravel])
    }

    @Test("nothing to measure against produces nothing")
    func emptyInputs() async throws {
        let walked = route([
            (47.6300, Self.baseLongitude),
            (47.6320, Self.baseLongitude),
        ])

        let withoutGraph = try await TrailBreakdownAnalyzer.breakdown(
            of: TrailSurface.self,
            route: walked,
            graph: .empty
        )
        let withoutRoute = try await TrailBreakdownAnalyzer.breakdown(
            of: TrailSurface.self,
            route: [walked[0]],
            graph: splitGraph()
        )

        #expect(withoutGraph.isEmpty)
        #expect(withoutRoute.isEmpty)
    }

    @Test("a sparse import is sampled along its legs, not just at its fixes")
    func samplesLongSegments() async throws {
        // Two fixes a kilometre apart, with only the first 20% of the leg on a
        // mapped way. Attributing whole legs to the way nearest an endpoint
        // would report all or none of it; sampling reports the fifth that is.
        let endLatitude = 47.6300 + 1000 / metersPerDegreeLatitude
        let mappedEnd = 47.6300 + 200 / metersPerDegreeLatitude
        let graph = makeGraph(
            nodes: [
                (1, 47.6300, Self.baseLongitude),
                (2, mappedEnd, Self.baseLongitude),
            ],
            ways: [WayFixture(id: 10, nodeIDs: [1, 2], surface: "asphalt")]
        )
        let walked = route([
            (47.6300, Self.baseLongitude),
            (endLatitude, Self.baseLongitude),
        ])

        let breakdown = try await TrailBreakdownAnalyzer.breakdown(
            of: TrailSurface.self,
            route: walked,
            graph: graph
        )

        let paved = try #require(
            breakdown.shares.first { $0.category == .paved }
        )
        #expect(abs(paved.fraction - 0.2) < 0.05)
        #expect(abs(breakdown.totalMeters - 1000) < 5)
    }
}
