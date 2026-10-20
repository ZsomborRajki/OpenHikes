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
    private static var route: [RouteCoordinate] {
        var line: [CLLocationCoordinate2D] = []
        for index in 0...100 { line.append(point(north: Double(index) * 10, east: 0)) }
        for index in (0...100).reversed() { line.append(point(north: Double(index) * 10, east: 3)) }
        return line.map { RouteCoordinate($0) }
    }

    /// Where a perfect hiker is `step` fixes in: ten metres a fix, out and back.
    private static func fix(at step: Int) -> (coordinate: CLLocationCoordinate2D, course: Double) {
        step <= 100
            ? (point(north: Double(step) * 10, east: 0), 0)
            : (point(north: Double(200 - step) * 10, east: 3), 180)
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
            let (coordinate, course) = Self.fix(at: step)
            let (found, contraryFixes) = FollowAnchor.advance(
                anchor, on: profile, to: coordinate, course: course, scope: .wholeRoute
            )
            let match = try #require(found)
            #expect(match.offRouteMeters <= RouteProfile.followMatchThresholdMeters)
            anchor = .matched(
                at: match.distanceAlongRoute, course: course, from: anchor, contraryFixes: contraryFixes
            )
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
            let (coordinate, course) = Self.fix(at: step)
            let (found, contraryFixes) = FollowAnchor.advance(
                anchor, on: profile, to: coordinate, course: course, scope: .wholeRoute
            )
            let match = try #require(found)
            anchor = .matched(
                at: match.distanceAlongRoute, course: course, from: anchor, contraryFixes: contraryFixes
            )
        }

        let standing = Self.point(north: 500, east: 0)
        for _ in 0..<(FollowAnchor.contraryFixesToSwitch - 1) {
            let (found, contraryFixes) = FollowAnchor.advance(
                anchor, on: profile, to: standing, course: 180, scope: .wholeRoute
            )
            let match = try #require(found)
            #expect(match.distanceAlongRoute < profile.totalDistanceMeters / 2, "still on the way out")
            anchor = .matched(
                at: match.distanceAlongRoute, course: 180, from: anchor, contraryFixes: contraryFixes
            )
        }
    }
}
