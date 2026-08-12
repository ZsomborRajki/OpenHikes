//
//  TrailMatcherTests.swift
//  OpenTrailsTests
//

import CoreLocation
import Foundation
import Testing
@testable import OpenTrails

@Suite("Trail matcher")
struct TrailMatcherTests {
    private let start = Date(timeIntervalSince1970: 1_750_000_000)

    @Test("dense noisy fixes snap onto named trail geometry")
    func denseTraceSnaps() throws {
        let graph = graph(
            nodes: [
                (1, 47.6300, 12.8600),
                (2, 47.6306, 12.8600)
            ],
            ways: [(10, [1, 2], "Ridge Path")]
        )
        let points = [
            point(47.6300, 12.86010, at: 0),
            point(47.6302, 12.86010, at: 10),
            point(47.6304, 12.86010, at: 20)
        ]

        let result = TrailMatcher.match(points: points, graph: graph)

        #expect(result.matchedLegCount == 2)
        #expect(result.didMoveRoute)
        #expect(result.matchedTrailName == "Ridge Path")
        #expect(result.currentTrailName == "Ridge Path")
        #expect(result.points.allSatisfy {
            abs($0.longitude - 12.8600) < 0.00001
        })
    }

    @Test("pedometer distance selects the plausible path through a sparse gap")
    func pedometerConstrainsGap() throws {
        let fixture = forkedGraph()
        let points = [
            point(47.6300, 12.8600, at: 0, accuracy: 5),
            point(47.6300, 12.8640, at: 720, accuracy: 5)
        ]

        let result = TrailMatcher.match(
            points: points,
            graph: fixture.graph,
            gapDistances: [1: fixture.northDistance]
        )

        #expect(result.matchedLegCount == 1)
        #expect(result.ambiguousLegCount == 0)
        #expect(result.didMoveRoute)
        #expect(result.points.map(\.latitude).max() ?? 0 > 47.633)
    }

    @Test("similar paths through a sparse gap stay raw without distance evidence")
    func ambiguousGapAbstains() throws {
        let fixture = forkedGraph()
        let points = [
            point(47.6300, 12.8600, at: 0, accuracy: 5),
            point(47.6300, 12.8640, at: 720, accuracy: 5)
        ]

        let result = TrailMatcher.match(points: points, graph: fixture.graph)

        #expect(result.matchedLegCount == 0)
        #expect(result.ambiguousLegCount == 1)
        #expect(result.currentTrailName == nil)
        #expect(!result.didMoveRoute)
        #expect(result.points == points)
        let ambiguity = try #require(result.ambiguities.first)
        #expect(ambiguity.alternatives.count >= 2)
        let alternative = try #require(ambiguity.alternatives.first)
        let resolved = result.points(
            resolving: [
                ambiguity.id: .alternative(alternative.id)
            ]
        )
        #expect(resolved != points)
        #expect(resolved.first?.coordinate.latitude == points.first?.latitude)
        #expect(resolved.first?.coordinate.longitude == points.first?.longitude)
        #expect(resolved.last?.coordinate.latitude == points.last?.latitude)
        #expect(resolved.last?.coordinate.longitude == points.last?.longitude)
        #expect(
            result.points(
                resolving: [ambiguity.id: .gps]
            ) == points
        )
    }

    @Test("parallel sparse candidates remain ambiguous")
    func parallelSparseTrailsAbstain() {
        let graph = graph(
            nodes: [
                (1, 47.6299, 12.8500),
                (2, 47.6299, 12.8700),
                (3, 47.6301, 12.8500),
                (4, 47.6301, 12.8700)
            ],
            ways: [
                (10, [1, 2], "South Trail"),
                (20, [3, 4], "North Trail")
            ]
        )
        let points = [
            point(47.6300, 12.8580, at: 0, accuracy: 30),
            point(47.6300, 12.8620, at: 720, accuracy: 30)
        ]

        let result = TrailMatcher.match(points: points, graph: graph)

        #expect(result.matchedLegCount == 0)
        #expect(result.ambiguousLegCount == 1)
        #expect(result.points == points)
    }

    @Test("pedometer evidence can select a same-edge turnaround")
    func sameEdgeTurnaroundUsesDistanceEvidence() {
        let graph = graph(
            nodes: [
                (1, 47.6300, 12.8600),
                (2, 47.6310, 12.8600)
            ],
            ways: [(10, [1, 2], "Out and Back Trail")]
        )
        let points = [
            point(47.6303, 12.8600, at: 0, accuracy: 5),
            point(47.6304, 12.8600, at: 720, accuracy: 5)
        ]
        let expectedDistance =
            RouteGeometry.distanceMeters(
                from: graph.nodes[0].coordinate,
                to: points[0].coordinate
            )
            + RouteGeometry.distanceMeters(
                from: graph.nodes[0].coordinate,
                to: points[1].coordinate
            )

        let result = TrailMatcher.match(
            points: points,
            graph: graph,
            gapDistances: [1: expectedDistance]
        )

        #expect(result.matchedLegCount == 1)
        #expect(result.ambiguousLegCount == 0)
        #expect(result.didMoveRoute)
        #expect(result.points.count > 2)
        #expect(result.points.map { $0.latitude }.min() == 47.6300)
    }

    @Test("projection and matching take the short path across the antimeridian")
    func antimeridianTrace() {
        let graph = graph(
            nodes: [
                (1, -17.7000, 179.95),
                (2, -17.7100, -179.95)
            ],
            ways: [(10, [1, 2], "Date Line Trail")]
        )
        let points = [
            point(-17.6999, 179.95, at: 0, accuracy: 20),
            point(-17.7099, -179.95, at: 5_000, accuracy: 20)
        ]

        let result = TrailMatcher.match(
            points: points,
            graph: graph,
            gapDistances: [1: 10_700]
        )

        #expect(result.matchedLegCount == 1)
        #expect(result.points.allSatisfy { abs($0.longitude) > 170 })
    }

    private func point(
        _ latitude: Double,
        _ longitude: Double,
        at offset: TimeInterval,
        accuracy: Double = 8
    ) -> RecordingPoint {
        RecordingPoint(
            latitude: latitude,
            longitude: longitude,
            timestamp: start.addingTimeInterval(offset),
            elevation: 600 + offset / 60,
            horizontalAccuracy: accuracy
        )
    }

    private func graph(
        nodes: [(Int64, Double, Double)],
        ways: [(Int64, [Int64], String?)]
    ) -> TrailGraph {
        let graphNodes = nodes.map {
            TrailGraphNode(
                id: $0.0,
                coordinate: CLLocationCoordinate2D(
                    latitude: $0.1,
                    longitude: $0.2
                )
            )
        }
        let byID = Dictionary(
            uniqueKeysWithValues: graphNodes.map { ($0.id, $0) }
        )
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
        return TrailGraph(nodes: graphNodes, edges: edges)
    }

    private func forkedGraph() -> (
        graph: TrailGraph,
        northDistance: Double
    ) {
        let nodes: [(Int64, Double, Double)] = [
            (1, 47.6300, 12.8600), // start
            (2, 47.6302, 12.8600), // west junction
            (3, 47.6340, 12.8600),
            (4, 47.6340, 12.8640),
            (5, 47.6302, 12.8640), // east junction
            (6, 47.6300, 12.8640), // finish
            (7, 47.6260, 12.8600),
            (8, 47.6260, 12.8640)
        ]
        let ways: [(Int64, [Int64], String?)] = [
            (10, [1, 2], "Fork Trail"),
            (11, [2, 3, 4, 5], "North Fork"),
            (12, [2, 7, 8, 5], "South Fork"),
            (13, [5, 6], "Fork Trail")
        ]
        let graph = graph(nodes: nodes, ways: ways)
        let northIDs: Set<Int64> = [10, 11, 13]
        let distance = graph.edges
            .filter { northIDs.contains($0.id.wayID) }
            .reduce(0) { $0 + $1.lengthMeters }
        return (graph, distance)
    }
}
