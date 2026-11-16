//
//  TrailLegRouterIndexTests.swift
//  OpenHikesTests
//
//  The one graph index the hiking router keeps between legs, and when it is
//  built again.
//
//  The router outlives every drawing, and the provider's graph for the same
//  ground changes under it: a region that was missing arrives, one that
//  expired is fetched again, and OpenStreetMap gains and loses paths in
//  between. The claims held still here:
//
//  - **A leg is routed over the graph it was handed**, never over an index
//    of the graph the last leg was handed for the same regions — whether that
//    graph has gained a path since or lost one.
//  - **An unchanged graph is indexed once**, even assembled afresh for each
//    leg, so moving a stop within the same ground stays cheap.
//
//  Through a stub provider, never the network — see *Deliberate test seams*.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import RealModule
import Testing

@Suite("Trail leg router's graph index")
struct TrailLegRouterIndexTests {
    /// Two paths running due north in the western region, about 750 m apart:
    /// far enough that a tap on one never snaps to the other.
    private enum Paths {
        static let firstLongitude = 12.70
        static let secondLongitude = 12.71
        static let latitudes = [47.700, 47.701, 47.702, 47.703, 47.704]
    }

    /// One way's segments between consecutive `points`, its nodes numbered
    /// from `firstNode`.
    private static func way(
        _ id: Int64,
        through points: [CLLocationCoordinate2D],
        firstNode: Int64,
        firstSegment: Int = 0
    ) -> TrailGraph {
        let nodes = points.enumerated().map { offset, point in
            TrailGraphNode(id: firstNode + Int64(offset), coordinate: point)
        }
        let edges = zip(nodes, nodes.dropFirst()).enumerated().map { offset, pair in
            TrailGraphEdge(
                id: TrailGraphEdgeID(wayID: id, segmentIndex: firstSegment + offset),
                fromNodeID: pair.0.id,
                toNodeID: pair.1.id,
                lengthMeters: RouteGeometry.distanceMeters(from: pair.0.coordinate, to: pair.1.coordinate),
                highway: "path"
            )
        }
        return TrailGraph(nodes: nodes, edges: edges)
    }

    private static func northward(along longitude: Double) -> [CLLocationCoordinate2D] {
        Paths.latitudes.map { CLLocationCoordinate2D(latitude: $0, longitude: longitude) }
    }

    private static let first = way(10, through: northward(along: Paths.firstLongitude), firstNode: 1)
    private static let second = way(20, through: northward(along: Paths.secondLongitude), firstNode: 11)

    private static func ends(
        along longitude: Double,
        from start: Int,
        to end: Int
    ) -> TrailLegEnds {
        let points = northward(along: longitude)
        return TrailLegEnds(
            from: TrailWaypoint(coordinate: points[start]),
            to: TrailWaypoint(coordinate: points[end])
        )
    }

    private static func isAlong(_ longitude: Double, _ route: TrailLegRoute) -> Bool {
        route.coordinates.allSatisfy { point in
            point.longitude.isApproximatelyEqual(to: longitude, absoluteTolerance: 0.0001)
        }
    }

    // MARK: A changed graph

    /// A path the region did not hold when the last leg was routed — a region
    /// fetched again, or one that was missing and has arrived.
    @Test("a path the same regions have gained since the last leg is routed over")
    func gainedPathIsRouted() async throws {
        let provider = RegionalTrailGraphProvider(graphs: [RegionalTrailGraphProvider.west: Self.first])
        let router = OverpassTrailLegRouter(provider: provider)

        let before = try #require(await router.route(Self.ends(along: Paths.firstLongitude, from: 0, to: 3)))
        await provider.replace(Self.first.merging(Self.second), in: RegionalTrailGraphProvider.west)
        let after = try #require(await router.route(Self.ends(along: Paths.secondLongitude, from: 0, to: 3)))

        #expect(before.snap == .snapped)
        #expect(after.snap == .snapped, "the new path is in the graph the leg was handed")
        #expect(Self.isAlong(Paths.secondLongitude, after))
    }

    /// The other direction: a path the region no longer holds is not one a
    /// leg can be drawn along.
    @Test("a path the same regions have lost since the last leg is not routed over")
    func lostPathIsNotRouted() async throws {
        let provider = RegionalTrailGraphProvider(
            graphs: [RegionalTrailGraphProvider.west: Self.first.merging(Self.second)]
        )
        let router = OverpassTrailLegRouter(provider: provider)

        let before = try #require(await router.route(Self.ends(along: Paths.secondLongitude, from: 0, to: 3)))
        await provider.replace(Self.first, in: RegionalTrailGraphProvider.west)
        let after = try #require(await router.route(Self.ends(along: Paths.secondLongitude, from: 1, to: 4)))

        #expect(before.snap == .snapped)
        #expect(after.snap == .unmapped(.noPathBetween), "the path is gone from the graph the leg was handed")
    }

    // MARK: An unchanged graph

    /// Two legs across both regions, each handed a graph the provider merged
    /// afresh from the same two halves: equal, though not the same storage.
    @Test("an unchanged graph is indexed once, even assembled afresh for each leg")
    func unchangedGraphIsIndexedOnce() async throws {
        let across = [12.790, 12.796, 12.802, 12.808, 12.814].map { longitude in
            CLLocationCoordinate2D(latitude: 47.75, longitude: longitude)
        }
        let provider = RegionalTrailGraphProvider(graphs: [
            RegionalTrailGraphProvider.west: Self.way(30, through: Array(across[...2]), firstNode: 21),
            RegionalTrailGraphProvider.east: Self.way(30, through: Array(across[2...]), firstNode: 23, firstSegment: 2),
        ])
        let router = OverpassTrailLegRouter(provider: provider)

        let whole = try #require(await router.route(
            TrailLegEnds(from: TrailWaypoint(coordinate: across[0]), to: TrailWaypoint(coordinate: across[4]))
        ))
        let inner = try #require(await router.route(
            TrailLegEnds(from: TrailWaypoint(coordinate: across[1]), to: TrailWaypoint(coordinate: across[3]))
        ))

        #expect(whole.snap == .snapped)
        #expect(inner.snap == .snapped)
        #expect(await router.indexBuildCount == 1, "the second leg reuses the first one's index")
    }
}
