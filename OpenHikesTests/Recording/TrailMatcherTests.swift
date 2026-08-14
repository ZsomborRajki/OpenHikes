//
//  TrailMatcherTests.swift
//  OpenHikesTests
//

import CoreLocation
import Foundation
@testable import OpenHikes
import Testing

@Suite("Trail matcher")
struct TrailMatcherTests {
    private let start = Date(timeIntervalSince1970: 1_750_000_000)

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
            horizontalAccuracy: accuracy,
            elevation: 600 + offset / 60
        )
    }

    private func graph(
        nodes: [(Int64, Double, Double)],
        ways: [(Int64, [Int64], String?)]
    ) -> TrailGraph {
        let graphNodes = nodes.map { node in
            TrailGraphNode(
                id: node.0,
                coordinate: CLLocationCoordinate2D(
                    latitude: node.1,
                    longitude: node.2
                )
            )
        }
        let byID = Dictionary(
            uniqueKeysWithValues: graphNodes.map { ($0.id, $0) }
        )
        var edges: [TrailGraphEdge] = []
        for way in ways {
            for index in 0..<(way.1.count - 1) {
                guard let from = byID[way.1[index]],
                      let to = byID[way.1[index + 1]] else { continue }
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
            (8, 47.6260, 12.8640),
        ]
        let ways: [(Int64, [Int64], String?)] = [
            (10, [1, 2], "Fork Trail"),
            (11, [2, 3, 4, 5], "North Fork"),
            (12, [2, 7, 8, 5], "South Fork"),
            (13, [5, 6], "Fork Trail"),
        ]
        let graph = graph(nodes: nodes, ways: ways)
        let northIDs: Set<Int64> = [10, 11, 13]
        let distance = graph.edges
            .filter { northIDs.contains($0.id.wayID) }
            .reduce(0) { $0 + $1.lengthMeters }
        return (graph, distance)
    }
}

extension TrailMatcherTests {
    @Test("dense noisy fixes snap onto named trail geometry")
    func denseTraceSnaps() {
        let graph = graph(
            nodes: [
                (1, 47.6300, 12.8600),
                (2, 47.6306, 12.8600),
            ],
            ways: [(10, [1, 2], "Ridge Path")]
        )
        let points = [
            point(47.6300, 12.86010, at: 0),
            point(47.6302, 12.86010, at: 10),
            point(47.6304, 12.86010, at: 20),
        ]

        let result = TrailMatcher.match(points: points, graph: graph)

        #expect(result.matchedLegCount == 2)
        #expect(result.didMoveRoute)
        #expect(result.matchedTrailName == "Ridge Path")
        #expect(result.currentTrailName == "Ridge Path")
        #expect(result.points.allSatisfy { point in
            abs(point.longitude - 12.8600) < 0.00001
        })
    }

    @Test("pedometer distance selects the plausible path through a sparse gap")
    func pedometerConstrainsGap() {
        let fixture = forkedGraph()
        let points = [
            point(47.6300, 12.8600, at: 0, accuracy: 5),
            point(47.6300, 12.8640, at: 720, accuracy: 5),
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
            point(47.6300, 12.8640, at: 720, accuracy: 5),
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
                (4, 47.6301, 12.8700),
            ],
            ways: [
                (10, [1, 2], "South Trail"),
                (20, [3, 4], "North Trail"),
            ]
        )
        let points = [
            point(47.6300, 12.8580, at: 0, accuracy: 30),
            point(47.6300, 12.8620, at: 720, accuracy: 30),
        ]

        let result = TrailMatcher.match(points: points, graph: graph)

        #expect(result.matchedLegCount == 0)
        #expect(result.ambiguousLegCount == 1)
        #expect(result.points == points)
    }

    @Test("disconnected sparse candidates do not invent a reviewable ambiguity")
    func disconnectedSparseCandidatesAreNotAmbiguous() {
        let graph = graph(
            nodes: [
                (1, 47.6300, 12.8600),
                (2, 47.6310, 12.8600),
                (3, 47.6500, 12.9000),
                (4, 47.6510, 12.9000),
            ],
            ways: [
                (10, [1, 2], "West Trail"),
                (20, [3, 4], "East Trail"),
            ]
        )
        let points = [
            point(47.6305, 12.8600, at: 0, accuracy: 5),
            point(47.6505, 12.9000, at: 720, accuracy: 5),
        ]

        let result = TrailMatcher.match(points: points, graph: graph)

        #expect(result.ambiguousLegCount == 0)
        #expect(result.ambiguities.isEmpty)
        #expect(result.ambiguousLegCount == result.ambiguities.count)
        #expect(result.points == points)
    }

    @Test("pedometer evidence can select a same-edge turnaround")
    func sameEdgeTurnaroundUsesDistanceEvidence() {
        let graph = graph(
            nodes: [
                (1, 47.6300, 12.8600),
                (2, 47.6310, 12.8600),
            ],
            ways: [(10, [1, 2], "Out and Back Trail")]
        )
        let points = [
            point(47.6303, 12.8600, at: 0, accuracy: 5),
            point(47.6304, 12.8600, at: 720, accuracy: 5),
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
        #expect(result.points.map(\.latitude).min() == 47.6300)
    }

    @Test("projection and matching take the short path across the antimeridian")
    func antimeridianTrace() {
        let graph = graph(
            nodes: [
                (1, -17.7000, 179.95),
                (2, -17.7100, -179.95),
            ],
            ways: [(10, [1, 2], "Date Line Trail")]
        )
        let points = [
            point(-17.6999, 179.95, at: 0, accuracy: 20),
            point(-17.7099, -179.95, at: 5000, accuracy: 20),
        ]

        let result = TrailMatcher.match(
            points: points,
            graph: graph,
            gapDistances: [1: 10_700]
        )

        #expect(result.matchedLegCount == 1)
        #expect(result.points.allSatisfy { abs($0.longitude) > 170 })
    }

    // MARK: Candidate search

    // The candidate search narrows the graph with a uniform grid before
    // projecting. A grid's failure mode is silent: it hides an edge the
    // exhaustive scan would have found, and matching quietly falls back to the
    // raw trace. These cover the cases where its bookkeeping could do that.

    @Test("a poor fix searches beyond one grid cell")
    func wideSearchRadiusSpansCells() {
        // Accuracy 100 gives a 300 m search radius, so the fix and the trail
        // sit in different cells: the query has to widen with the radius
        // rather than trusting the cell the fix landed in.
        let graph = graph(
            nodes: [
                (1, 47.6300, 12.8600),
                (2, 47.6320, 12.8600),
            ],
            ways: [(10, [1, 2], "Wide Trail")]
        )
        let points = [
            point(47.6302, 12.8620, at: 0, accuracy: 100),
            point(47.6307, 12.8620, at: 60, accuracy: 100),
            point(47.6312, 12.8620, at: 120, accuracy: 100),
        ]

        let result = TrailMatcher.match(points: points, graph: graph)

        #expect(result.matchedTrailName == "Wide Trail")
        #expect(result.didMoveRoute)
    }

    @Test("a segment longer than the grid's reach is still found")
    func edgeLongerThanGridReachStillMatches() {
        // One kilometre between OSM nodes puts this edge past the half-length
        // the grid will bucket, so it can only be found on the always-scanned
        // path.
        let graph = graph(
            nodes: [
                (1, 47.6300, 12.8600),
                (2, 47.6390, 12.8600),
            ],
            ways: [(10, [1, 2], "Long Straight")]
        )
        let points = [
            point(47.6320, 12.86012, at: 0),
            point(47.6325, 12.86012, at: 60),
            point(47.6330, 12.86012, at: 120),
        ]

        let result = TrailMatcher.match(points: points, graph: graph)

        #expect(result.matchedTrailName == "Long Straight")
        #expect(result.didMoveRoute)
    }

    @Test("a walk far from the graph's first edge still matches")
    func matchesFarFromGridOrigin() {
        // Grid cells are laid out around the first edge's start. A walk twenty
        // kilometres away exercises the shared frame at the range where its
        // scale error would show up.
        let graph = graph(
            nodes: [
                (1, 47.6300, 12.8600),
                (2, 47.6320, 12.8600),
                (3, 47.6300, 13.1265),
                (4, 47.6320, 13.1265),
            ],
            ways: [
                (10, [1, 2], "Near Trail"),
                (11, [3, 4], "Far Trail"),
            ]
        )
        let points = [
            point(47.6302, 13.12652, at: 0),
            point(47.6307, 13.12652, at: 60),
            point(47.6312, 13.12652, at: 120),
        ]

        let result = TrailMatcher.match(points: points, graph: graph)

        #expect(result.matchedTrailName == "Far Trail")
        #expect(result.didMoveRoute)
    }

    @Test("the nearest of many parallel trails wins the shortlist")
    func nearestOfManyParallelTrailsWins() {
        // The shortlist keeps only the closest few candidates, so an edge
        // offered twice would evict a genuine one. Eleven parallel trails
        // around the walker is more than that shortlist holds.
        var nodes: [(Int64, Double, Double)] = []
        var ways: [(Int64, [Int64], String?)] = []
        for offset in -5...5 {
            let longitude = 12.8600 + Double(offset) * 0.0004
            let first = Int64(offset + 5) * 2 + 1
            nodes.append((first, 47.6300, longitude))
            nodes.append((first + 1, 47.6320, longitude))
            ways.append((Int64(offset + 5) + 10, [first, first + 1], "Trail \(offset)"))
        }
        let points = [
            point(47.6302, 12.86005, at: 0, accuracy: 30),
            point(47.6307, 12.86005, at: 60, accuracy: 30),
            point(47.6312, 12.86005, at: 120, accuracy: 30),
        ]

        let result = TrailMatcher.match(
            points: points,
            graph: graph(nodes: nodes, ways: ways)
        )

        #expect(result.matchedTrailName == "Trail 0")
        #expect(result.points.allSatisfy { point in
            abs(point.longitude - 12.8600) < 0.00001
        })
    }
}
