//
//  RouteProfileHeadingFirstTests.swift
//  OpenHikesDataTests
//
//  The background feed's matcher, on the shape continuity alone gets wrong:
//  an out-and-back whose two legs are a few metres apart (#836). Held by
//  continuity, a hiker walking home is placed on the outbound leg's mirror,
//  so the walk's coverage stops at the turn and never reaches the end. The
//  foreground answers that with patience — `FollowAnchor` waits for three
//  fixes that disagree (#865) — which a significant-location-change feed, a
//  fix every five hundred metres at best, cannot afford.
//
//  One fix at a time on the foreground's matcher is
//  `RouteProfileTests+Matching`, and the foreground's run around the turn is
//  `OutAndBackFollowTests`; these are the sparse feed's.
//

import CoreLocation
import Foundation
@testable import OpenHikesData
import OpenHikesShared
import RealModule
import Testing

@Suite("Heading-first route matching")
struct RouteProfileHeadingFirstTests {
    private static let metersPerDegreeLatitude = 111_320.0
    private static let metersPerDegreeLongitude = 111_320.0 * cos(47 * Double.pi / 180)

    /// How far a match may sit from the point under its fix. Every projection
    /// within ``RouteProfile/tieBreakToleranceMeters`` of the closest is tied,
    /// and continuity settles the tie toward the previous match, so a match
    /// trails the hiker by up to that much.
    private static let tolerance = RouteProfile.tieBreakToleranceMeters + 5

    private static func point(north: Double, east: Double = 0) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(
            latitude: 47 + north / metersPerDegreeLatitude,
            longitude: 12 + east / metersPerDegreeLongitude
        )
    }

    /// A kilometre north, then a kilometre back along the same path, the
    /// return leg `returnOffset` metres to the east, a point every ten metres.
    private static func outAndBack(returnOffset: Double = 3) -> RouteProfile {
        var line: [CLLocationCoordinate2D] = []
        for index in 0...100 { line.append(point(north: Double(index) * 10)) }
        for index in (0...100).reversed() { line.append(point(north: Double(index) * 10, east: returnOffset)) }
        return RouteProfile(route: line.map { RouteCoordinate($0) })
    }

    /// How far along `profile` its return leg passes `north` metres up the trail.
    private static func returnLeg(at north: Double, of profile: RouteProfile) -> Double {
        profile.totalDistanceMeters - north
    }

    /// One delivery can carry a hiker from the outbound leg past the turn and
    /// most of the way home, which puts the return leg under them outside the
    /// window continuity searches.
    @Test("one sparse fix past the turn lands on the return leg outside the continuity window")
    func sparseFixCrossesToTheReturnLeg() throws {
        let profile = Self.outAndBack()
        let reference = 700.0
        let expected = Self.returnLeg(at: 200, of: profile)
        try #require(expected - reference > RouteProfile.continuitySearchRadiusMeters)

        let match = try #require(profile.nearestPointHeadingFirst(
            to: Self.point(north: 200, east: 3),
            near: reference,
            heading: 180
        ))
        #expect(
            match.distanceAlongRoute.isApproximatelyEqual(to: expected, absoluteTolerance: Self.tolerance),
            "matched at \(match.distanceAlongRoute)"
        )
    }

    /// The whole route is searched only for a leg the window's tie would have
    /// admitted. One running the hiker's way ten metres beyond it is a
    /// different trail, though well inside the follow threshold.
    @Test("a leg running the hiker's way beyond the tie is a different trail")
    func legBeyondTheTieIsNotAContender() throws {
        let profile = Self.outAndBack(returnOffset: RouteProfile.tieBreakToleranceMeters + 10)
        let match = try #require(profile.nearestPointHeadingFirst(
            to: Self.point(north: 200),
            near: 200,
            heading: 180
        ))
        #expect(
            match.distanceAlongRoute.isApproximatelyEqual(to: 200, absoluteTolerance: Self.tolerance),
            "matched at \(match.distanceAlongRoute)"
        )
    }

    /// The cost of believing the course: one pointing the wrong way moves the
    /// match to the other leg. It lasts that one fix — the next with an
    /// honest course moves it back, even from outside the window around where
    /// the wrong one left it.
    @Test("a course pointing the wrong way costs one fix, not the walk")
    func wrongCourseCostsOneFix() throws {
        let profile = Self.outAndBack()
        let misled = try #require(profile.nearestPointHeadingFirst(
            to: Self.point(north: 300),
            near: 300,
            heading: 180
        ))
        let recovered = try #require(profile.nearestPointHeadingFirst(
            to: Self.point(north: 310),
            near: misled.distanceAlongRoute,
            heading: 0
        ))
        #expect(
            recovered.distanceAlongRoute.isApproximatelyEqual(to: 310, absoluteTolerance: Self.tolerance),
            "matched at \(recovered.distanceAlongRoute)"
        )
    }

    /// Out and back at two hundred metres a fix, each matched against the
    /// last as `BackgroundTrailTracker` does, into the coverage a walk
    /// accrues. Too sparse for three contrary fixes to switch legs before the
    /// hiker is most of the way home, close enough that coverage bridges
    /// every step (``TrailWalkPolicy/gapBoundMeters``).
    @Test("a sparse walk home along the return leg reaches the end")
    func sparseWalkHomeReachesTheEnd() throws {
        let profile = Self.outAndBack()
        let outbound = stride(from: 0.0, through: 1000, by: 200).map { north in
            (coordinate: Self.point(north: north), course: 0.0)
        }
        let homeward = stride(from: 800.0, through: 0, by: -200).map { north in
            (coordinate: Self.point(north: north, east: 3), course: 180.0)
        }
        var walk = TrailWalkRecord(
            hikeID: UUID(),
            routeDistanceMeters: profile.totalDistanceMeters,
            startedAt: Date(timeIntervalSince1970: 0)
        )
        var reference: Double?
        for fix in outbound + homeward {
            let match = try #require(profile.nearestPointHeadingFirst(
                to: fix.coordinate,
                near: reference,
                heading: fix.course
            ))
            walk.coverage.record(distance: match.distanceAlongRoute)
            reference = match.distanceAlongRoute
        }

        let last = try #require(reference)
        #expect(walk.coveredFraction >= TrailWalkPolicy.reachedEndFraction, "covered \(walk.coveredFraction)")
        #expect(walk.reachesEnd(atMatch: last), "last matched at \(last) of \(profile.totalDistanceMeters)")
    }

    /// The rule is the watch's, so the two should put the hiker in the same
    /// place on every fix — which the constants `WatchFixPolicyParityTests`
    /// holds equal cannot show. The walk is #836's reproduction, a fix every
    /// ten metres with an exact course, on which continuity alone put every
    /// fix past the turn on the outbound leg's mirror while the watch followed
    /// the hiker home.
    @Test("puts the hiker where the watch does, fix by fix, out and back")
    func agreesWithTheWatch() throws {
        let profile = Self.outAndBack()
        var watch = WatchRouteTracker(WatchTrailPackage(
            hikeID: UUID(),
            title: "Out and back",
            tintHex: "#000000",
            totalDistanceMeters: profile.totalDistanceMeters,
            points: profile.coordinates.map { WatchTrailPoint(latitude: $0.latitude, longitude: $0.longitude) }
        ))
        var reference: Double?
        var worst = (step: 0, phone: 0.0, watch: 0.0)
        for step in 0...200 {
            let homeward = step > 100
            let fix = Self.point(north: Double(homeward ? 200 - step : step) * 10, east: homeward ? 3 : 0)
            let course = homeward ? 180.0 : 0
            let phone = try #require(profile.nearestPointHeadingFirst(to: fix, near: reference, heading: course))
            let advanced = watch.advance(latitude: fix.latitude, longitude: fix.longitude, courseDegrees: course)
            let wrist = try #require(advanced)
            if abs(phone.distanceAlongRoute - wrist.distanceAlongRouteMeters) > abs(worst.phone - worst.watch) {
                worst = (step, phone.distanceAlongRoute, wrist.distanceAlongRouteMeters)
            }
            if phone.offRouteMeters <= RouteProfile.followMatchThresholdMeters {
                reference = phone.distanceAlongRoute
            }
        }
        // A metre lets `RouteGeometry` and `WatchGeodesy` round differently; the
        // other leg is over twenty metres away one fix past the turn, and
        // twenty more with every fix after it.
        #expect(
            worst.phone.isApproximatelyEqual(to: worst.watch, absoluteTolerance: 1),
            "fix \(worst.step): phone \(worst.phone), watch \(worst.watch)"
        )
    }
}
