//
//  WatchRouteTrackerPauseTests.swift
//  OpenHikesSharedTests
//
//  The watch's half of #962. A trail recorded with a pause in it reaches the
//  watch as one line, and the leg joining the two recorded pieces is ground
//  the hiker drove or rode across. The phone's `RouteProfile` gives that leg no
//  length and never matches onto it; the watch has to read the same line the
//  same way, or it calls a car park on the trail and tells a hiker they are
//  further along than the phone does.
//

import Foundation
@testable import OpenHikesShared
import RealModule
import Testing

// swiftlint:disable no_magic_numbers

@Suite("Watch route tracker across a pause")
struct WatchRouteTrackerPauseTests {
    /// A thousandth of a degree of longitude on the equator.
    private static let step = WatchGeodesy.distanceMeters(
        fromLatitude: 0,
        longitude: 0,
        toLatitude: 0,
        longitude: 0.001
    )

    /// 111 m walked, a kilometre driven, 111 m walked — sent with the hike's
    /// own distance, which leaves the drive out, as the phone's does.
    private static let package = WatchTrailPackage(
        hikeID: UUID(),
        title: "Two pieces",
        tintHex: "#1B7F3B",
        totalDistanceMeters: 2 * step,
        points: [0, 0.001, 0.010, 0.011].map { WatchTrailPoint(latitude: 0, longitude: $0) },
        pauseIndices: [2]
    )

    @Test("a fix in the middle of the transfer is not on the trail")
    func transferIsNotTrail() throws {
        var tracker = WatchRouteTracker(Self.package)

        let reading = tracker.advance(latitude: 0, longitude: 0.005)
        let middle = try #require(reading)

        #expect(!middle.isOnTrail)
        #expect(middle.offRouteMeters > WatchRouteTracker.matchThresholdMeters)
    }

    @Test("progress after a pause counts the walking, not the drive")
    func progressLeavesTheTransferOut() throws {
        var tracker = WatchRouteTracker(Self.package)

        let reading = tracker.advance(latitude: 0, longitude: 0.0105)
        let after = try #require(reading)

        #expect(after.isOnTrail)
        #expect(after.distanceAlongRouteMeters.isApproximatelyEqual(to: 1.5 * Self.step, absoluteTolerance: 1))
        #expect(after.fractionComplete.isApproximatelyEqual(to: 0.75, absoluteTolerance: 0.01))
    }

    @Test("a pause is part of what the watch holds, so moving one is a new revision")
    func pausesAreInTheRevision() {
        var unpaused = Self.package
        unpaused.pauseIndices = []

        #expect(unpaused.revision != Self.package.revision)
    }

    @Test("the pauses survive the link")
    func pausesCrossTheLink() throws {
        let crossed = try WatchLink.trailPackage(from: WatchLink.message(Self.package))

        #expect(crossed.pauseIndices == [2])
    }
}

// swiftlint:enable no_magic_numbers
