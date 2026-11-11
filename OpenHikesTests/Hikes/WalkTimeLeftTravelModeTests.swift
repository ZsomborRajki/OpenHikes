//
//  WalkTimeLeftTravelModeTests.swift
//  OpenHikesTests
//
//  The time left on a trail drawn for something other than hiking — timed at
//  that mode's pace, with no climb, and scaled by the walk's own — and where
//  the map stands the figure on the line.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import RealModule
import Testing

@Suite("Walk time left by travel mode")
struct WalkTimeLeftTravelModeTests {
    /// Six kilometres due north, climbing 600 m over the first half and flat
    /// over the second — `WalkTimeLeftTests`' trail.
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

    /// The same six kilometres with no heights at all.
    private static let flat = RouteProfile(route: (0...60).map { step in
        RouteCoordinate(latitude: 47.0 + Double(step) * 0.0009, longitude: 11.0)
    })

    private static func walked(_ intervals: Double...) -> TrailWalkCoverage {
        TrailWalkCoverage(intervals: intervals, furthestDistanceMeters: 0)
    }

    /// The 600 m climb is in the hiking figure and not in the ride's: a
    /// mode's pace is the maker's, and the maker counts a climb for hiking
    /// alone.
    @Test("a trail drawn for walking, cycling or driving is timed at that pace, with no climb", arguments: [
        TrailTravelMode.walking, .cycling, .driving,
    ])
    func aVehicleIsTimedAtItsOwnPace(mode: TrailTravelMode) throws {
        let total = Self.profile.totalDistanceMeters
        let seconds = try #require(WalkTimeLeft.seconds(
            profile: Self.profile,
            position: 0,
            coverage: TrailWalkCoverage(),
            activeSeconds: 0,
            travelMode: mode
        ))
        #expect(seconds.isApproximatelyEqual(to: total / mode.paceMetersPerSecond, absoluteTolerance: 0.001))

        let hiking = try #require(WalkTimeLeft.seconds(
            profile: Self.profile,
            position: 0,
            coverage: TrailWalkCoverage(),
            activeSeconds: 0
        ))
        let flatHike = WalkingTimeEstimate.seconds(distanceMeters: total, ascentMeters: 0, descentMeters: 0)
        #expect(hiking > flatHike, "and on foot the climb still counts")
    }

    /// With no heights, a hiker's flat figure is out by a factor of two on an
    /// alpine route and is not shown. A ride's flat figure is the maker's own.
    @Test("with no heights and no calibration, a ride still has a figure and a hike does not")
    func aRideNeedsNoHeights() throws {
        let total = Self.flat.totalDistanceMeters
        #expect(WalkTimeLeft.seconds(
            profile: Self.flat,
            position: 0,
            coverage: TrailWalkCoverage(),
            activeSeconds: 0
        ) == nil)
        let ride = try #require(WalkTimeLeft.seconds(
            profile: Self.flat,
            position: 0,
            coverage: TrailWalkCoverage(),
            activeSeconds: 0,
            travelMode: .cycling
        ))
        #expect(ride.isApproximatelyEqual(
            to: total / TrailTravelMode.cycling.paceMetersPerSecond,
            absoluteTolerance: 0.001
        ))
    }

    /// Half the trail ridden at two thirds of the maker's pace: the rest is
    /// taken at the rider's, as a hiker's is.
    @Test("a slow rider's own pace stretches a ride's time left")
    func aRidersOwnPaceCounts() throws {
        let total = Self.profile.totalDistanceMeters
        let covered = Self.walked(0, total / 2)
        let pace = TrailTravelMode.cycling.paceMetersPerSecond
        // Eighteen minutes, past the calibration's fifteen.
        let ridden = (total / 2) / pace * 1.5

        let factor = try #require(WalkTimeLeft.paceFactor(
            profile: Self.profile,
            coverage: covered,
            activeSeconds: ridden,
            travelMode: .cycling
        ))
        #expect(factor.isApproximatelyEqual(to: 1.5, absoluteTolerance: 0.001))

        let left = try #require(WalkTimeLeft.seconds(
            profile: Self.profile,
            position: total / 2,
            coverage: covered,
            activeSeconds: ridden,
            travelMode: .cycling
        ))
        #expect(left.isApproximatelyEqual(to: (total / 2) / pace * 1.5, absoluteTolerance: 0.01))
    }

    /// Halfway between the hiker and the end the walk is going for, whichever
    /// end that is.
    @Test("the time left stands halfway along the way ahead, either way round")
    func theMarkIsHalfwayAhead() {
        let total = 6000.0
        let onwards = WalkTimeLeft.midwayAhead(position: 2000, coverage: Self.walked(0, 2000), routeMeters: total)
        #expect(onwards.isApproximatelyEqual(to: 4000, absoluteTolerance: 0.001))

        let back = WalkTimeLeft.midwayAhead(position: 4000, coverage: Self.walked(6000, 4000), routeMeters: total)
        #expect(back.isApproximatelyEqual(to: 2000, absoluteTolerance: 0.001))
    }
}
