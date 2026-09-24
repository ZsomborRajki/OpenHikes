//
//  WalkTimeLeftTests.swift
//  OpenHikesTests
//
//  How long the rest of a followed trail takes — the signposts' rule over
//  what is left, scaled by how this walk compares with them so far.
//

import Foundation
@testable import OpenHikes
import OpenHikesShared
import Testing

@Suite("Walk time left")
struct WalkTimeLeftTests {
    /// Six kilometres due north, climbing 600 m over the first half and
    /// flat over the second.
    private static let profile: RouteProfile = {
        let steps = 60
        let route = (0...steps).map { step in
            RouteCoordinate(
                latitude: 47.0 + Double(step) * 0.0009,
                longitude: 11.0,
                elevation: 1000 + Double(min(step, steps / 2)) * 20
            )
        }
        return RouteProfile(route: route)
    }()

    @Test("a stretch's climb is counted from its lower end to its higher")
    func climbBetweenTwoDistances() throws {
        let total = Self.profile.totalDistanceMeters
        // The profile's own distance for the turn, so the boundary sample is
        // inside the stretch rather than a rounding error either side of it.
        let turn = Self.profile.distances[30]
        let firstHalf = try #require(Self.profile.climb(from: 0, to: turn))
        #expect(abs(firstHalf.gainMeters - 600) < 1)
        #expect(firstHalf.lossMeters == 0)
        let reversed = try #require(Self.profile.climb(from: turn, to: 0))
        #expect(reversed.gainMeters == firstHalf.gainMeters, "the order the ends are given in does not matter")

        let secondHalf = Self.profile.climb(from: turn, to: total)
        #expect((secondHalf?.gainMeters ?? 0) == 0, "the second half is flat")
    }

    /// Before calibration the estimate is the signposts' own.
    @Test("before the walk has covered enough, the signposts' time is the answer")
    func uncalibratedUsesTheSignposts() throws {
        let total = Self.profile.totalDistanceMeters
        let seconds = try #require(WalkTimeLeft.seconds(
            profile: Self.profile,
            position: 0,
            remainingMeters: total,
            covered: [],
            activeSeconds: 0
        ))
        let climb = try #require(Self.profile.climb(from: 0, to: total))
        let expected = WalkingTimeEstimate.seconds(
            distanceMeters: total,
            ascentMeters: climb.gainMeters,
            descentMeters: climb.lossMeters
        )
        #expect(abs(seconds - expected) < 0.001)
    }

    /// A hiker taking twice the signposts' time over the climb is taken at
    /// their word for the rest of it.
    @Test("a slow walk's own pace stretches the time left")
    func aSlowWalkTakesLonger() throws {
        let total = Self.profile.totalDistanceMeters
        let covered = [0...(total / 2)]
        let climb = try #require(Self.profile.climb(from: 0, to: total / 2))
        let signposts = WalkingTimeEstimate.seconds(
            distanceMeters: total / 2,
            ascentMeters: climb.gainMeters,
            descentMeters: climb.lossMeters
        )
        let factor = try #require(WalkTimeLeft.paceFactor(
            profile: Self.profile,
            covered: covered,
            activeSeconds: signposts * 1.5
        ))
        #expect(abs(factor - 1.5) < 0.001)

        let left = try #require(WalkTimeLeft.seconds(
            profile: Self.profile,
            position: total / 2,
            remainingMeters: total / 2,
            covered: covered,
            activeSeconds: signposts * 1.5
        ))
        let flatRest = WalkingTimeEstimate.seconds(distanceMeters: total / 2, ascentMeters: 0, descentMeters: 0)
        #expect(abs(left - flatRest * 1.5) < 1)
    }

    @Test("the walk's own pace is bounded both ways")
    func thePaceFactorIsBounded() throws {
        let total = Self.profile.totalDistanceMeters
        let covered = [0...(total / 2)]
        let sprint = try #require(
            WalkTimeLeft.paceFactor(profile: Self.profile, covered: covered, activeSeconds: 16 * 60)
        )
        let crawl = try #require(
            WalkTimeLeft.paceFactor(profile: Self.profile, covered: covered, activeSeconds: 20 * 3600)
        )
        #expect(sprint == WalkTimeLeft.paceFactorBounds.lowerBound)
        #expect(crawl == WalkTimeLeft.paceFactorBounds.upperBound)
    }

    @Test("too little covered, or too little time, is not a pace")
    func calibrationNeedsDistanceAndTime() {
        #expect(WalkTimeLeft.paceFactor(profile: Self.profile, covered: [0...500], activeSeconds: 3600) == nil)
        #expect(WalkTimeLeft.paceFactor(profile: Self.profile, covered: [0...3000], activeSeconds: 600) == nil)
    }

    /// A flat figure on a route with no heights is the error the estimate
    /// exists to correct — until the walk's own pace stands in for them.
    @Test("no heights and no calibration is no figure")
    func noHeightsNoCalibrationIsNothing() {
        let flat = RouteProfile(route: (0...10).map { step in
            RouteCoordinate(latitude: 47.0 + Double(step) * 0.001, longitude: 11.0)
        })
        let total = flat.totalDistanceMeters
        #expect(WalkTimeLeft.seconds(
            profile: flat,
            position: 0,
            remainingMeters: total,
            covered: [],
            activeSeconds: 0
        ) == nil)
    }

    @Test("nothing left is no time left")
    func nothingLeftIsNothing() {
        #expect(WalkTimeLeft.seconds(
            profile: Self.profile,
            position: Self.profile.totalDistanceMeters,
            remainingMeters: 0,
            covered: [],
            activeSeconds: 0
        ) == nil)
    }
}
