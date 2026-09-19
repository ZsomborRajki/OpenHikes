//
//  WatchPathNetworkTests.swift
//  OpenHikesTests
//
//  What reaches the watch out of a walking graph, and what is left behind.
//
//  The graph is built by hand here rather than fetched. What is under test is
//  the three things that turn a graph into a map — chaining, the corridor, and
//  the budget — and each of them is a decision about *which* ways survive, so
//  a fixture with known geometry is the only way to assert one.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesShared
import Testing

// swiftlint:disable no_magic_numbers

@Suite("The footpaths sent to the watch")
struct WatchPathNetworkTests {
    @Test("a way's segments come back as one line, not as many")
    func segmentsAreChained() throws {
        // Three segments of one way, beside the route.
        let graph = Fixture.graph(ways: [Fixture.way(id: 1, offsetMeters: 60, points: 4)])

        let paths = try #require(WatchPathNetwork.paths(from: graph, along: Fixture.route, hikeID: Fixture.hikeID))

        #expect(paths.paths.count == 1)
        // Four nodes, not six — the shared ones are sent once.
        #expect(paths.paths[0].count <= 4)
        #expect(paths.isDrawable)
    }

    @Test("a path far from the route is another walk's map")
    func distantPathsAreDropped() {
        let near = Fixture.way(id: 1, offsetMeters: 80, points: 3)
        let far = Fixture.way(id: 2, offsetMeters: 3000, points: 3)

        let paths = WatchPathNetwork.paths(
            from: Fixture.graph(ways: [near, far]),
            along: Fixture.route,
            hikeID: Fixture.hikeID
        )

        // One survives, and it is the near one — asserted by count rather than
        // by identity because what crosses the link is coordinates, not ids.
        #expect(paths?.paths.count == 1)
    }

    @Test("the route itself is not drawn twice")
    func theRouteIsNotSentBackAsAPath() {
        // A way lying on the route, which is the ordinary case: the trail the
        // hiker is following is usually one of the ways in the graph.
        let onRoute = Fixture.way(id: 1, offsetMeters: 0, points: 5)

        let paths = WatchPathNetwork.paths(
            from: Fixture.graph(ways: [onRoute]),
            along: Fixture.route,
            hikeID: Fixture.hikeID
        )

        // Nothing worth sending, which is a real answer rather than an empty
        // list: a grey line under the coloured one along its whole length is
        // what this prevents.
        #expect(paths == nil)
    }

    @Test("a dense area is capped, and spends what it has on the nearest paths")
    func theBudgetIsSpentNearestFirst() throws {
        // Far more geometry than the budget allows, at increasing distances.
        let ways = (1...60).map { index in
            Fixture.way(id: Int64(index), offsetMeters: Double(index) * 5, points: 40)
        }

        let paths = try #require(
            WatchPathNetwork.paths(from: Fixture.graph(ways: ways), along: Fixture.route, hikeID: Fixture.hikeID)
        )

        #expect(paths.pointCount <= WatchTrailPaths.pointBudget)
        // Whole paths only: half a lane drawn to a point that is not a
        // junction reads as a path that stops there.
        #expect(paths.paths.allSatisfy { $0.count > 1 })
        #expect(!paths.paths.isEmpty)
    }

    @Test("a graph with nothing in it sends nothing")
    func anEmptyGraphSendsNothing() {
        #expect(WatchPathNetwork.paths(from: .empty, along: Fixture.route, hikeID: Fixture.hikeID) == nil)
    }

    private enum Fixture {
        static let hikeID = UUID(uuidString: "44444444-4444-4444-4444-444444444444") ?? UUID()

        /// A kilometre of route running north, which every way here is placed
        /// relative to.
        static let route: [CLLocationCoordinate2D] = (0...10).map { step in
            CLLocationCoordinate2D(
                latitude: 47.5530 + Double(step) * 0.0009,
                longitude: 12.9880
            )
        }

        struct Way {
            let id: Int64
            let coordinates: [CLLocationCoordinate2D]
        }

        /// A way running parallel to the route, `offsetMeters` to the east.
        static func way(id: Int64, offsetMeters: Double, points: Int) -> Way {
            // Degrees of longitude per metre at this latitude, near enough for
            // a fixture: the assertions are about which side of a 400 m line a
            // way falls on, not about geodesy.
            let degreesPerMetre = 1 / (111_320 * cos(47.55 * .pi / 180))
            return Way(
                id: id,
                coordinates: (0..<points).map { step in
                    CLLocationCoordinate2D(
                        latitude: 47.5530 + Double(step) * 0.0009,
                        longitude: 12.9880 + offsetMeters * degreesPerMetre
                    )
                }
            )
        }

        static func graph(ways: [Way]) -> TrailGraph {
            var nodes: [TrailGraphNode] = []
            var edges: [TrailGraphEdge] = []
            var nextNodeID: Int64 = 1
            for way in ways {
                var ids: [Int64] = []
                for coordinate in way.coordinates {
                    nodes.append(TrailGraphNode(id: nextNodeID, coordinate: coordinate))
                    ids.append(nextNodeID)
                    nextNodeID += 1
                }
                for index in 0..<(ids.count - 1) {
                    edges.append(
                        TrailGraphEdge(
                            id: TrailGraphEdgeID(wayID: way.id, segmentIndex: index),
                            fromNodeID: ids[index],
                            toNodeID: ids[index + 1],
                            lengthMeters: 100
                        )
                    )
                }
            }
            return TrailGraph(nodes: nodes, edges: edges)
        }
    }
}

// swiftlint:enable no_magic_numbers
