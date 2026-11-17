//
//  WatchTrailPackagingJunctionTests.swift
//  OpenHikesTests
//
//  The junctions a trail crosses to the watch with: found on the phone's
//  trail graph, and put on the scale the watch reports a position on.
//

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

    @Test("with no trail graph, the trail crosses without junctions")
    func noGraphNoJunctions() async throws {
        let hike = Fixture.hike(in: context, title: "Fork Trail", route: JunctionFixture.route)

        let package = try #require(await WatchTrailPackaging.package(from: HikeRouteInput(hike: hike)))

        #expect(package.junctions.isEmpty)
        #expect(package.isDrawable)
    }
}

// swiftlint:enable no_magic_numbers
