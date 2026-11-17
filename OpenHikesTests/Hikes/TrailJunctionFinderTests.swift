//
//  TrailJunctionFinderTests.swift
//  OpenHikesTests
//
//  The junctions a followed trail's line passes, read off small graphs laid
//  out in metres east and north of one point, and what is said at each
//  walking either way.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import OpenHikesShared
import RealModule
import Testing

// swiftlint:disable no_magic_numbers

@Suite("Trail junction finder")
struct TrailJunctionFinderTests {
    private static let origin = CLLocationCoordinate2D(latitude: 47.0, longitude: 11.0)

    /// The point `east` and `north` metres from the origin.
    private static func at(_ east: Double, _ north: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(
            latitude: origin.latitude + north / RouteGeometry.metersPerDegreeLatitude,
            longitude: origin.longitude + east
                / (RouteGeometry.metersPerDegreeLatitude * cos(origin.latitude * .pi / 180))
        )
    }

    /// A graph of trails, each a list of numbered points; points with the
    /// same number are one node, which is what joins two trails.
    private static func graph(
        _ points: [Int64: (Double, Double)],
        trails: [[Int64]],
        highway: String = "path"
    ) -> TrailGraph {
        let nodes = points.map { id, point in
            TrailGraphNode(id: id, coordinate: at(point.0, point.1))
        }
        var edges: [TrailGraphEdge] = []
        for (way, trail) in trails.enumerated() {
            for (index, pair) in zip(trail, trail.dropFirst()).enumerated() {
                edges.append(TrailGraphEdge(
                    id: TrailGraphEdgeID(wayID: Int64(way), segmentIndex: index),
                    fromNodeID: pair.0,
                    toNodeID: pair.1,
                    lengthMeters: 1,
                    highway: highway
                ))
            }
        }
        return TrailGraph(nodes: nodes, edges: edges)
    }

    private static func profile(_ points: [(Double, Double)], pausedAt paused: Set<Int> = []) -> RouteProfile {
        RouteProfile(route: points.enumerated().map { index, point in
            let coordinate = at(point.0, point.1)
            return RouteCoordinate(
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                boundary: paused.contains(index) ? .paused : nil
            )
        })
    }

    /// A Y: the stem from the south, the left arm going on north-north-west
    /// and the right arm north-north-east, meeting at node 1 at (0, 0).
    private static let fork = graph(
        [0: (0, -200), 1: (0, 0), 2: (-70, 200), 3: (70, 200)],
        trails: [[0, 1, 2], [1, 3]]
    )

    @Test("a line up the stem of a Y and on along its left arm keeps left, and says nothing coming back")
    func forkKeepsLeft() throws {
        let line = Self.profile([(0, -200), (0, 0), (-70, 200)])

        let junctions = TrailJunctionFinder.junctions(along: line, in: Self.fork)

        let junction = try #require(junctions.first)
        #expect(junctions.count == 1)
        #expect(junction.distanceMeters.isApproximatelyEqual(to: 200, absoluteTolerance: 1))
        #expect(junction.towardsEnd == .keepLeft)
        // Coming back down, the right arm joins from behind: the way on is
        // plain.
        #expect(junction.towardsStart == nil)
    }

    @Test("the right arm of the same Y keeps right")
    func forkKeepsRight() throws {
        let line = Self.profile([(0, -200), (0, 0), (70, 200)])

        #expect(try #require(TrailJunctionFinder.junctions(along: line, in: Self.fork).first).towardsEnd == .keepRight)
    }

    @Test("a line that turns at a T says which way, both ways")
    func teeTurns() throws {
        let tee = Self.graph(
            [0: (0, -200), 1: (0, 0), 2: (-200, 0), 3: (200, 0)],
            trails: [[0, 1], [2, 1, 3]]
        )
        let line = Self.profile([(0, -200), (0, 0), (-200, 0)])

        let junction = try #require(TrailJunctionFinder.junctions(along: line, in: tee).first)

        #expect(junction.towardsEnd == .turnLeft)
        #expect(junction.towardsStart == .turnRight)
    }

    @Test("a turn back on itself is a sharp one")
    func sharpTurn() throws {
        let hairpin = Self.graph(
            [0: (0, -200), 1: (0, 0), 2: (-150, -120), 3: (0, 200)],
            trails: [[0, 1, 3], [1, 2]]
        )
        let line = Self.profile([(0, -200), (0, 0), (-150, -120)])

        #expect(try #require(TrailJunctionFinder.junctions(along: line, in: hairpin).first).towardsEnd == .sharpLeft)
    }

    @Test("straight over a crossroads is said nowhere")
    func crossroadsIsSilent() {
        let crossroads = Self.graph(
            [0: (0, -200), 1: (0, 0), 2: (0, 200), 3: (-200, 0), 4: (200, 0)],
            trails: [[0, 1, 2], [3, 1, 4]]
        )
        let line = Self.profile([(0, -200), (0, 200)])

        #expect(TrailJunctionFinder.junctions(along: line, in: crossroads).isEmpty)
    }

    @Test("a line that passes a junction without following its ways says nothing there")
    func lineOffTheWaysIsSilent() {
        // The line crosses the node heading east, along none of its ways.
        let line = Self.profile([(-200, 0), (0, 0), (200, 0)])

        #expect(TrailJunctionFinder.junctions(along: line, in: Self.fork).isEmpty)
    }

    @Test("a junction further off the line than a recording wanders is not on it")
    func distantNodeIsNotOnTheLine() {
        let line = Self.profile([(40, -200), (40, 0), (-30, 200)])

        #expect(TrailJunctionFinder.junctions(along: line, in: Self.fork).isEmpty)
    }

    @Test("a recording a few metres off the path still finds the fork")
    func wanderingLineStillFindsTheFork() throws {
        let line = Self.profile([(6, -200), (5, -100), (7, 0), (-63, 200)])

        let junction = try #require(TrailJunctionFinder.junctions(along: line, in: Self.fork).first)

        #expect(junction.towardsEnd == .keepLeft)
    }

    @Test("a way's direction is read past the bend it is mapped with at the junction")
    func armReadsPastTheFirstNode() throws {
        // The right arm leaves due east for three metres, then bends north:
        // read at its first node it would be a turn, read along it a fork.
        let bent = Self.graph(
            [0: (0, -200), 1: (0, 0), 2: (-70, 200), 4: (3, 0.5), 3: (70, 200)],
            trails: [[0, 1, 2], [1, 4, 3]]
        )
        let line = Self.profile([(0, -200), (0, 0), (-70, 200)])

        #expect(try #require(TrailJunctionFinder.junctions(along: line, in: bent).first).towardsEnd == .keepLeft)
    }

    @Test("a stub that ends a few metres from the junction is no choice")
    func stubIsIgnored() {
        let stub = Self.graph(
            [0: (0, -200), 1: (0, 0), 2: (0, 200), 3: (2, 1)],
            trails: [[0, 1, 2], [1, 3]]
        )
        let line = Self.profile([(0, -200), (0, 200)])

        #expect(TrailJunctionFinder.junctions(along: line, in: stub).isEmpty)
    }

    @Test("a junction where the line was paused is not read across the pause")
    func pauseIsNotAJunction() {
        // The pause arrives at the fork, so the line reaches it along no way.
        let line = Self.profile([(0, -200), (0, -10), (0, 0), (-70, 200)], pausedAt: [2])

        #expect(TrailJunctionFinder.junctions(along: line, in: Self.fork).isEmpty)
    }

    @Test("roads in the graph join nothing a walk is told about")
    func roadsAreNotTrails() {
        let road = Self.graph(
            [0: (0, -200), 1: (0, 0), 2: (-70, 200), 3: (70, 200)],
            trails: [[0, 1, 2], [1, 3]],
            highway: "residential"
        )
        let line = Self.profile([(0, -200), (0, 0), (-70, 200)])

        #expect(TrailJunctionFinder.junctions(along: line, in: road).isEmpty)
    }

    @Test("a line through the same fork twice finds it twice")
    func outAndBackPassesTwice() {
        let line = Self.profile([(0, -200), (0, 0), (-70, 200), (0, 0), (0, -200)])

        let junctions = TrailJunctionFinder.junctions(along: line, in: Self.fork)

        #expect(junctions.count == 2)
        #expect(junctions.first?.towardsEnd == .keepLeft)
        #expect(junctions.last?.towardsStart == .keepLeft)
    }

    @Test("a hiker facing north sees a north-west way to the left and a north-east one to the right")
    func relativeAngles() {
        #expect(TrailJunctionFinder.relative(315, to: 0).isApproximatelyEqual(to: -45, absoluteTolerance: 1e-9))
        #expect(TrailJunctionFinder.relative(45, to: 0).isApproximatelyEqual(to: 45, absoluteTolerance: 1e-9))
        #expect(TrailJunctionFinder.relative(10, to: 350).isApproximatelyEqual(to: 20, absoluteTolerance: 1e-9))
        #expect(TrailJunctionFinder.relative(180, to: 0).isApproximatelyEqual(to: -180, absoluteTolerance: 1e-9))
    }
}

// swiftlint:enable no_magic_numbers
