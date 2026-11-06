//
//  RouteProfileProjectedCoordinateTests.swift
//  OpenHikesDataTests
//
//  The point a fix's projection fell on, answered beside its distance
//  (#1350). A pause is no distance (see ``RouteBoundary``), so a piece a
//  recording resumed on and never moved along shares its whole distance with
//  the fix before the pause, and ``RouteProfile/coordinate(atDistance:)``
//  reads that distance back as the fix before it, or as the start of the next
//  piece — a drive away from where the hiker stands. The live fix the widget
//  and the Lock Screen draw was read back that way, on both feeds.
//
//  Beside that, the thing that has to go on holding: on a route a distance
//  does name one place, the coordinate is that place.
//

import CoreLocation
import Foundation
@testable import OpenHikesData
import RealModule
import Testing

@Suite("The coordinate a projection fell on")
struct RouteProfileProjectedCoordinateTests {
    /// The ways a recording can resume without moving, about 111 km north of
    /// where it paused, after a kilometre walked.
    enum Piece: String, CaseIterable, Sendable {
        /// One more fix there, and the recording stopped.
        case atTheEnd = "at the route's end"
        /// One more fix there, then another pause and a drive on.
        case beforeAnotherPause = "before another pause"
        /// Several fixes standing there before walking on.
        case beforeWalkingOn = "before walking on"

        static let resumedAt = CLLocationCoordinate2D(latitude: 48, longitude: 12)

        private static func point(_ latitude: Double, _ boundary: RouteBoundary? = nil) -> RouteCoordinate {
            RouteCoordinate(latitude: latitude, longitude: resumedAt.longitude, boundary: boundary)
        }

        /// The kilometre walked, then the pause and the drive to ``resumedAt``.
        static let beforeThePause = [point(47), point(47.01), point(48, .paused)]

        var profile: RouteProfile {
            let standing = Self.point(Self.resumedAt.latitude)
            let resumed: [RouteCoordinate] = switch self {
            case .atTheEnd: [standing]
            case .beforeAnotherPause: [standing, Self.point(49, .paused), Self.point(49.01)]
            case .beforeWalkingOn: [standing, standing, Self.point(48.01)]
            }
            return RouteProfile(route: Self.beforeThePause + resumed)
        }

        /// Where the recording resumed, on the distance axis.
        var resume: Double { profile.distances[Self.beforeThePause.count - 1] }
    }

    /// The three ways a fix is projected: the foreground's first fix, its
    /// fixes after that, and the background feed's.
    enum Search: String, CaseIterable, Sendable {
        case cold = "with nothing to go on"
        case continuing = "from the last match"
        case headingFirst = "heading-first, walking north"

        func match(
            _ coordinate: CLLocationCoordinate2D,
            on profile: RouteProfile,
            near reference: Double
        ) -> (distanceAlongRoute: Double, offRouteMeters: Double, coordinate: CLLocationCoordinate2D)? {
            switch self {
            case .cold: profile.nearestPoint(to: coordinate)
            case .continuing: profile.nearestPoint(to: coordinate, near: reference)
            case .headingFirst: profile.nearestPointHeadingFirst(to: coordinate, near: reference, heading: 0)
            }
        }
    }

    /// A few metres east of where the recording resumed, which is a point of
    /// this trail and nowhere near the kilometre walked before the pause.
    @Test(
        "a fix where a recording resumed without moving is matched there",
        arguments: Piece.allCases, Search.allCases
    )
    func stationaryPieceKeepsItsProjection(piece: Piece, search: Search) throws {
        let resumedAt = Piece.resumedAt
        let beside = CLLocationCoordinate2D(latitude: resumedAt.latitude, longitude: resumedAt.longitude + 0.0001)

        let match = try #require(search.match(beside, on: piece.profile, near: piece.resume))

        #expect(RouteGeometry.distanceMeters(from: match.coordinate, to: resumedAt) < 1)
        #expect(match.offRouteMeters < 10)
    }

    /// Out along the equator for about 5.6 km and straight back, so a match
    /// on the outbound leg has a twin on the return one far outside the
    /// continuity window.
    private static let outAndBack = RouteProfile(route: [0, 0.05, 0].map { longitude in
        RouteCoordinate(latitude: 0, longitude: longitude)
    })

    /// With no pause a distance names one place, and the coordinate is it —
    /// on the heading-first search too when the course sends it round the
    /// turn, to the return leg, outside the window it searched first.
    @Test("on an unbroken route the coordinate is the one its distance reads back", arguments: [0.005, 0.03, 0.049])
    func unbrokenRouteAgreesWithItsDistance(longitude: Double) throws {
        let profile = Self.outAndBack
        let fix = CLLocationCoordinate2D(latitude: 0.0001, longitude: longitude)
        let outbound = try #require(profile.nearestPoint(to: CLLocationCoordinate2D(latitude: 0, longitude: longitude)))

        let cold = try #require(profile.nearestPoint(to: fix))
        let continuing = try #require(profile.nearestPoint(to: fix, near: outbound.distanceAlongRoute))
        let homeward = try #require(
            profile.nearestPointHeadingFirst(to: fix, near: outbound.distanceAlongRoute, heading: 270)
        )

        #expect(homeward.distanceAlongRoute > profile.totalDistanceMeters / 2, "precondition: round the turn")
        for match in [cold, continuing, homeward] {
            let readBack = try #require(profile.coordinate(atDistance: match.distanceAlongRoute))
            #expect(RouteGeometry.distanceMeters(from: match.coordinate, to: readBack) < 0.01)
            #expect(match.coordinate.longitude.isApproximatelyEqual(to: longitude, absoluteTolerance: 1e-7))
        }
    }

    @Test("a one-point route answers its point")
    func onePointRoute() throws {
        let only = CLLocationCoordinate2D(latitude: 47, longitude: 12)
        let profile = RouteProfile(route: [RouteCoordinate(only)])

        let fix = CLLocationCoordinate2D(latitude: 47.001, longitude: 12)
        let match = try #require(profile.nearestPoint(to: fix))
        let preferring = try #require(profile.nearestPoint(to: fix) { _ in true })

        for answer in [match, preferring] {
            #expect(answer.coordinate.latitude == only.latitude)
            #expect(answer.coordinate.longitude == only.longitude)
        }
    }
}
