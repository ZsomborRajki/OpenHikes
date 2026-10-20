//
//  OutAndBackFollowTests.swift
//  OpenHikesTests
//
//  Following a trail that retraces itself, end to end: the matcher the map
//  follows with, `FollowAnchor`'s hysteresis, and the coverage a walk accrues.
//
//  `TrailWalkCoverageTests` assume a matcher that reports increasing distance
//  past the turn of an out-and-back, and `RouteProfileTests+Matching` match one
//  fix at a time. Neither runs the three together, which is where a hiker
//  walking home is placed on the outbound leg.
//

import CoreLocation
import Foundation
import OpenHikesData
import Testing

@testable import OpenHikes

@Suite("Following an out-and-back")
struct OutAndBackFollowTests {
    private static let metersPerDegreeLatitude = 111_320.0
    private static let metersPerDegreeLongitude = 111_320.0 * cos(47 * Double.pi / 180)

    private static func point(north: Double, east: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(
            latitude: 47 + north / metersPerDegreeLatitude,
            longitude: 12 + east / metersPerDegreeLongitude
        )
    }

    /// A kilometre north, then a kilometre back along the same path, the
    /// return leg three metres to the east, a point every ten metres.
    private static var route: [RouteCoordinate] { route(returnOffset: 3) }

    private static func route(returnOffset: Double) -> [RouteCoordinate] {
        var line: [CLLocationCoordinate2D] = []
        for index in 0...100 { line.append(point(north: Double(index) * 10, east: 0)) }
        for index in (0...100).reversed() { line.append(point(north: Double(index) * 10, east: returnOffset)) }
        return line.map { RouteCoordinate($0) }
    }

    /// Where a perfect hiker is `step` fixes in: ten metres a fix, out and back.
    private static func fix(at step: Int) -> RouteFix {
        step <= 100
            ? routeFix(north: Double(step) * 10, second: Double(step), course: 0)
            : routeFix(north: Double(200 - step) * 10, second: Double(step), east: 3)
    }

    private static func routeFix(north: Double, second: Double, east: Double = 0, course: Double? = 180) -> RouteFix {
        RouteFix(
            coordinate: point(north: north, east: east),
            course: course,
            timestamp: Date(timeIntervalSince1970: second)
        )
    }

    @Test("reading one cached fix again does not count as another contrary fix")
    func cachedFixDoesNotSwitchLegs() throws {
        let profile = RouteProfile(route: Self.route)
        var anchor: FollowAnchor?
        _ = FollowAnchor.advance(
            &anchor, on: profile, to: Self.routeFix(north: 600, second: 0, course: 0), scope: .wholeRoute
        )
        let cached = Self.routeFix(north: 590, second: 1)
        for _ in 0..<5 {
            let match = try #require(FollowAnchor.advance(&anchor, on: profile, to: cached, scope: .wholeRoute))
            #expect(match.distanceAlongRoute < profile.totalDistanceMeters / 2)
        }
        let second = try #require(FollowAnchor.advance(
            &anchor, on: profile, to: Self.routeFix(north: 580, second: 2), scope: .wholeRoute
        ))
        #expect(second.distanceAlongRoute < profile.totalDistanceMeters / 2)
        let third = try #require(FollowAnchor.advance(
            &anchor, on: profile, to: Self.routeFix(north: 570, second: 3), scope: .wholeRoute
        ))
        #expect(third.distanceAlongRoute > profile.totalDistanceMeters / 2)
    }

    @Test("a heading cannot replace an on-trail match with an off-trail one")
    func offTrailOpinionIsIgnored() throws {
        let profile = RouteProfile(route: Self.route(returnOffset: 15))
        var anchor: FollowAnchor?
        _ = FollowAnchor.advance(
            &anchor, on: profile, to: Self.routeFix(north: 600, second: 0, course: 0), scope: .wholeRoute
        )
        for second in 1...5 {
            let fix = Self.routeFix(north: 600 - Double(second), second: Double(second), east: -70)
            let match = try #require(FollowAnchor.advance(&anchor, on: profile, to: fix, scope: .wholeRoute))
            #expect(match.offRouteMeters <= RouteProfile.followMatchThresholdMeters)
            #expect(match.distanceAlongRoute < profile.totalDistanceMeters / 2)
        }
    }

    @Test("an unusable or off-trail fix interrupts the run of contrary fixes", arguments: [false, true])
    func rejectedFixInterruptsContraryRun(offTrail: Bool) throws {
        let profile = RouteProfile(route: Self.route)
        var anchor: FollowAnchor?
        _ = FollowAnchor.advance(
            &anchor, on: profile, to: Self.routeFix(north: 600, second: 0, course: 0), scope: .wholeRoute
        )
        for second in 1...2 {
            let fix = Self.routeFix(north: 600 - Double(second), second: Double(second))
            _ = FollowAnchor.advance(&anchor, on: profile, to: fix, scope: .wholeRoute)
        }
        let rejected = offTrail ? Self.routeFix(north: 590, second: 3, east: -200) : nil
        _ = FollowAnchor.advance(&anchor, on: profile, to: rejected, scope: .wholeRoute)
        let resumed = try #require(FollowAnchor.advance(
            &anchor, on: profile, to: Self.routeFix(north: 590, second: 4), scope: .wholeRoute
        ))
        #expect(resumed.distanceAlongRoute < profile.totalDistanceMeters / 2)
    }

    @Test("a hiker walking home is followed along the return leg")
    func theReturnLegIsFollowed() throws {
        let profile = RouteProfile(route: Self.route)
        let total = profile.totalDistanceMeters
        var anchor: FollowAnchor?
        var coverage = TrailWalkCoverage()
        var furthest = 0.0
        var lastOnTheWayBack = 0.0

        for step in 0..<200 {
            let match = try #require(FollowAnchor.advance(
                &anchor, on: profile, to: Self.fix(at: step), scope: .wholeRoute
            ))
            #expect(match.offRouteMeters <= RouteProfile.followMatchThresholdMeters)
            coverage.record(distance: match.distanceAlongRoute)
            furthest = max(furthest, match.distanceAlongRoute)
            if step > 100 { lastOnTheWayBack = match.distanceAlongRoute }
        }

        #expect(furthest > total * 0.9, "furthest reported \(Int(furthest)) m of \(Int(total)) m")
        #expect(lastOnTheWayBack > total * 0.9, "home reads \(Int(lastOnTheWayBack)) m of \(Int(total)) m")
        let covered = try #require(coverage.fractionComplete(routeDistanceMeters: total))
        #expect(covered >= TrailWalkPolicy.reachedEndFraction, "coverage \(covered)")
    }

    /// The protection the course needs hysteresis for: a hiker halfway out who
    /// turns to look back down the trail for a couple of fixes has not started
    /// the return leg.
    @Test("a short look back does not move the hiker onto the return leg")
    func aLookBackIsIgnored() throws {
        let profile = RouteProfile(route: Self.route)
        var anchor: FollowAnchor?
        for step in 0...50 {
            _ = try #require(FollowAnchor.advance(
                &anchor, on: profile, to: Self.fix(at: step), scope: .wholeRoute
            ))
        }

        for second in 1..<FollowAnchor.contraryFixesToSwitch {
            let match = try #require(FollowAnchor.advance(
                &anchor, on: profile, to: Self.routeFix(north: 500, second: Double(50 + second)), scope: .wholeRoute
            ))
            #expect(match.distanceAlongRoute < profile.totalDistanceMeters / 2, "still on the way out")
        }
    }
}
