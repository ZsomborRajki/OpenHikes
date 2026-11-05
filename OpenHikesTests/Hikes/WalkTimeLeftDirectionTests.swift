//
//  WalkTimeLeftDirectionTests.swift
//  OpenHikesTests
//
//  Which end of the trail the time left is timing, once a walk's matches have
//  said which way it is going. Each test asserts the climb and the distance
//  the estimate chose as well as the time it came to: a figure alone can be
//  right for the wrong end (#1195), and a climb to one end can be timed over
//  the length of something else (#1304).
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import RealModule
import Testing

@Suite("Walk time left direction")
struct WalkTimeLeftDirectionTests {
    /// Ten kilometres due north, a point about every 100 m: the first eight
    /// rise 200 m, the last two climb another 1000 m.
    static let route: [RouteCoordinate] = (0...100).map { step in
        RouteCoordinate(
            latitude: 47.0 + Double(step) * 0.0009,
            longitude: 11.0,
            elevation: step <= 80 ? 1000 + Double(step) * 2.5 : 1200 + Double(step - 80) * 50
        )
    }

    private static let profile = RouteProfile(route: route)

    /// The coverage of a match at each of the route's points in `legs`, in
    /// order, a leg's first point following on from the last leg's end.
    private static func walked(_ legs: [Int]...) -> TrailWalkCoverage {
        var coverage = TrailWalkCoverage()
        for index in legs.joined() {
            coverage.record(distance: profile.distances[index])
        }
        return coverage
    }

    /// Point indices from `start` to `end`, inclusive, whichever way round.
    private static func leg(_ start: Int, _ end: Int) -> [Int] {
        Array(stride(from: start, through: end, by: start <= end ? 1 : -1))
    }

    /// What the line climbs and drops from `position` to its stored start,
    /// as a hiker walking there meets it.
    private static func climbToStart(from position: Double) throws -> (gainMeters: Double, lossMeters: Double) {
        let stretch = try #require(profile.climb(from: 0, to: position))
        return (stretch.lossMeters, stretch.gainMeters)
    }

    /// What the line climbs and drops from `position` to its stored end.
    private static func climbToEnd(from position: Double) throws -> (gainMeters: Double, lossMeters: Double) {
        try #require(profile.climb(from: position, to: profile.totalDistanceMeters))
    }

    /// Holds the estimate at `position` to the end `heading` names: the climb
    /// it chose, the distance, and the signposts' time for that climb over
    /// that distance, with calibration out of it. Both are the stretch from
    /// the hiker to that end, whatever the walk has covered (#1304).
    private func expectEstimate(
        at position: Double,
        coverage: TrailWalkCoverage,
        heading: TrailWalkDirection
    ) throws {
        let towardsStart = heading == .towardsStart
        let expected = try towardsStart ? Self.climbToStart(from: position) : Self.climbToEnd(from: position)
        let ahead = try #require(
            WalkTimeLeft.climbAhead(profile: Self.profile, position: position, coverage: coverage)
        )
        #expect(ahead.gainMeters.isApproximatelyEqual(to: expected.gainMeters, absoluteTolerance: 0.001))
        #expect(ahead.lossMeters.isApproximatelyEqual(to: expected.lossMeters, absoluteTolerance: 0.001))

        let remaining = towardsStart ? position : Self.profile.totalDistanceMeters - position
        let meters = WalkTimeLeft.metersAhead(
            position: position,
            coverage: coverage,
            routeMeters: Self.profile.totalDistanceMeters
        )
        #expect(meters.isApproximatelyEqual(to: remaining, absoluteTolerance: 0.001))
        let seconds = try #require(WalkTimeLeft.seconds(
            profile: Self.profile,
            position: position,
            coverage: coverage,
            activeSeconds: 0
        ))
        let signposts = WalkingTimeEstimate.seconds(
            distanceMeters: remaining,
            ascentMeters: expected.gainMeters,
            descentMeters: expected.lossMeters
        )
        #expect(seconds.isApproximatelyEqual(to: signposts, absoluteTolerance: 0.001))
    }

    /// The issue's walk. Up to the 8 km point, then 1.5 km back: most of the
    /// ground covered still lies beyond the hiker's back, so the coverage
    /// read this as carrying on, with 1000 m of climb still to come.
    @Test("a walk that turned back is timed downhill, however much it covered on the way up")
    func aTurnedWalkIsTimedBack() throws {
        let coverage = Self.walked(Self.leg(0, 80), Self.leg(79, 65))
        let position = Self.profile.distances[65]

        let ahead = try Self.climbToStart(from: position)
        #expect(ahead.gainMeters.isApproximatelyEqual(to: 0, absoluteTolerance: 0.001))
        #expect(ahead.lossMeters.isApproximatelyEqual(to: 162.5, absoluteTolerance: 1))
        try expectEstimate(at: position, coverage: coverage, heading: .towardsStart)
    }

    /// The same walk the other way up. Down from the stored end to the 3 km
    /// point, then 500 m back up: nearly all the coverage lies beyond the
    /// hiker, so the coverage read this as still going down.
    @Test("a walk from the stored end that turned back is timed up the climb")
    func aReversedWalkThatTurnedIsTimedOnwards() throws {
        let coverage = Self.walked(Self.leg(100, 30), Self.leg(31, 35))
        let position = Self.profile.distances[35]

        let ahead = try Self.climbToEnd(from: position)
        #expect(ahead.gainMeters > 1000)
        try expectEstimate(at: position, coverage: coverage, heading: .towardsEnd)
    }

    /// One union and one position, and only the order of the matches differs.
    @Test("the same ground and position are timed the way the walk is going")
    func theUnionDoesNotChoose() throws {
        let turned = Self.walked(Self.leg(0, 80), Self.leg(79, 65))
        let onward = Self.walked(Self.leg(0, 80), Self.leg(79, 60), Self.leg(61, 65))
        let position = Self.profile.distances[65]
        #expect(turned.ranges == onward.ranges)

        try expectEstimate(at: position, coverage: turned, heading: .towardsStart)
        try expectEstimate(at: position, coverage: onward, heading: .towardsEnd)
    }

    @Test("a walk set off from the start is timed to the end")
    func aForwardStart() throws {
        let position = Self.profile.distances[20]
        try expectEstimate(at: position, coverage: Self.walked(Self.leg(0, 20)), heading: .towardsEnd)
    }

    @Test("a walk set off from the stored end is timed to the start")
    func aReverseStart() throws {
        let position = Self.profile.distances[80]
        try expectEstimate(at: position, coverage: Self.walked(Self.leg(100, 80)), heading: .towardsStart)
    }

    /// From the middle, where the nearer end says nothing about which way
    /// the hiker set off.
    @Test("a walk set off from the middle is timed the way it set off", arguments: [(60, 45), (40, 55)])
    func aMiddleStart(start: Int, end: Int) throws {
        let position = Self.profile.distances[end]
        try expectEstimate(
            at: position,
            coverage: Self.walked(Self.leg(start, end)),
            heading: end < start ? .towardsStart : .towardsEnd
        )
    }

    /// A match 40 m behind the one before it, each way. The estimate is read
    /// from where the hiker last matched, and keeps the end it was timing.
    @Test("a small GPS backstep keeps the end the walk was going for")
    func aBackstepKeepsTheEnd() throws {
        var onward = Self.walked(Self.leg(0, 20))
        let behind = Self.profile.distances[20] - 40
        onward.record(distance: behind)
        try expectEstimate(at: behind, coverage: onward, heading: .towardsEnd)

        var back = Self.walked(Self.leg(100, 80))
        let ahead = Self.profile.distances[80] + 40
        back.record(distance: ahead)
        try expectEstimate(at: ahead, coverage: back, heading: .towardsStart)
    }

    /// A pause or a fix off the route says nothing about which way the hiker
    /// is going, so a walk that comes back behind itself is timed as it was.
    @Test("a break in the walk keeps the end it was going for")
    func aBreakKeepsTheEnd() throws {
        var coverage = Self.walked(Self.leg(0, 80))
        coverage.breakContinuity()
        let position = Self.profile.distances[50]
        coverage.record(distance: position)

        try expectEstimate(at: position, coverage: coverage, heading: .towardsEnd)
    }
}
