//
//  WatchTrailPackagingJunctionTests.swift
//  OpenHikesTests
//
//  The junctions a trail crosses to the watch with: found on the phone's
//  trail graph, and put where the watch reads a fix at each.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import OpenHikesShared
import RealModule
import SwiftData
import Testing

// swiftlint:disable no_magic_numbers

@MainActor
@Suite("Packaging a trail's junctions for the watch")
struct WatchTrailPackagingJunctionTests {
    private let context: ModelContext

    init() throws {
        context = ModelContext(try Fixture.modelContainer())
    }

    @Test("the fork on the trail crosses, where the watch will measure it")
    func junctionsCross() async throws {
        let hike = Fixture.hike(in: context, title: "Fork Trail", route: JunctionFixture.route)
        let lineLength = hike.distanceMeters
        // The trail's own length, which the watch reports positions on, a
        // tenth longer than the line: the junction is moved with it.
        hike.distanceMeters = lineLength * 1.1

        let package = try #require(await WatchTrailPackaging.package(
            from: HikeRouteInput(hike: hike),
            graph: StubTrailGraphProvider(graph: JunctionFixture.fork)
        ))

        let junction = try #require(package.junctions.first)
        #expect(package.junctions.count == 1)
        #expect(junction.towardsEnd == .keepLeft)
        #expect(junction.distanceMeters.isApproximatelyEqual(to: 440, absoluteTolerance: 2))
    }

    @Test("a junction after a straight approach and before switchbacks is where the watch reads a fix there")
    func junctionMatchesTheWatchsReading() async throws {
        // Four kilometres straight north to a junction, then switchbacks:
        // decimation takes far more length out of the switchbacks, so the
        // trail scaled as a whole put the junction half a kilometre off.
        let approach = (0...4000).map { RouteCoordinate(JunctionFixture.at(0, Double($0) - 4000)) }
        let switchbacks = (1...1200).map { index in
            RouteCoordinate(JunctionFixture.at(50 * sin(Double(index) * .pi / 10), Double(index) * 2))
        }
        let hike = Fixture.hike(in: context, title: "Switchbacks", route: approach + switchbacks)
        let graph = TrailGraph(
            nodes: [
                TrailGraphNode(id: 0, coordinate: JunctionFixture.at(0, -4000)),
                TrailGraphNode(id: 1, coordinate: JunctionFixture.at(0, 0)),
                TrailGraphNode(id: 2, coordinate: JunctionFixture.at(200, 20)),
                TrailGraphNode(id: 3, coordinate: JunctionFixture.at(-200, 200)),
            ],
            edges: [
                JunctionFixture.edge(way: 0, index: 0, from: 0, to: 1),
                JunctionFixture.edge(way: 0, index: 1, from: 1, to: 2),
                JunctionFixture.edge(way: 1, index: 0, from: 1, to: 3),
            ]
        )

        let package = try #require(await WatchTrailPackaging.package(
            from: HikeRouteInput(hike: hike),
            graph: StubTrailGraphProvider(graph: graph)
        ))
        let junction = try #require(package.junctions.first)
        var tracker = WatchRouteTracker(package)
        var position: WatchRouteTracker.Position?
        for north in stride(from: -200.0, through: 0, by: 10) {
            let fix = JunctionFixture.at(0, north)
            position = tracker.advance(latitude: fix.latitude, longitude: fix.longitude, courseDegrees: 0)
        }
        let atJunction = try #require(position)

        #expect(package.points.count < hike.route.count)
        // Within the tracker's own tie-break: legs that close to a fix are
        // settled by continuity, which on a straight stretch of short legs
        // reads a step behind. Scaled as a whole, it was 511 m.
        #expect(atJunction.distanceAlongRouteMeters.isApproximatelyEqual(
            to: junction.distanceMeters,
            absoluteTolerance: WatchRouteTracker.tieBreakToleranceMeters
        ))
    }

    @Test("with no trail graph, the trail crosses without junctions")
    func noGraphNoJunctions() async throws {
        let hike = Fixture.hike(in: context, title: "Fork Trail", route: JunctionFixture.route)

        let package = try #require(await WatchTrailPackaging.package(from: HikeRouteInput(hike: hike)))

        #expect(package.junctions.isEmpty)
        #expect(package.isDrawable)
    }
}

// swiftlint:enable no_magic_numbers
