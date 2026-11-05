//
//  RouteProfilePreferredTieTests.swift
//  OpenHikesDataTests
//
//  A projection that lets the caller say which stretches count (#1114). On an
//  out-and-back every point has a twin on the other leg, and the plain search
//  answers the outbound one; a caller that knows the return leg is the one
//  that matters gets it — and gets nothing else, because a preferred stretch
//  that is not tied with the closest is another piece of trail.
//

import CoreLocation
import Foundation
@testable import OpenHikesData
import RealModule
import Testing

@Suite("A preferred tie on the route profile")
struct RouteProfilePreferredTieTests {
    /// Out along the equator for about 2.2 km and straight back.
    private static let outAndBack = RouteProfile(route: [0, 0.02, 0].map { longitude in
        RouteCoordinate(latitude: 0, longitude: longitude, elevation: nil)
    })

    private static let turn = outAndBack.distances[1]
    private static let midpoint = CLLocationCoordinate2D(latitude: 0, longitude: 0.01)

    @Test("a tie on the leg the caller prefers goes to that leg")
    func preferredTieWins() throws {
        let profile = Self.outAndBack
        let plain = try #require(profile.nearestPoint(to: Self.midpoint))
        let preferred = try #require(profile.nearestPoint(to: Self.midpoint) { $0 > Self.turn })

        #expect(plain.distanceAlongRoute < Self.turn)
        #expect(preferred.distanceAlongRoute.isApproximatelyEqual(
            to: Self.turn * 1.5,
            absoluteTolerance: 1e-3
        ))
        #expect(preferred.offRouteMeters.isApproximatelyEqual(to: plain.offRouteMeters, absoluteTolerance: 1e-6))
    }

    /// A point a few hundred metres short of the turn is on both legs, so a
    /// preference only for the far end of the return leg — which is a
    /// kilometre and more away — must not drag it there.
    @Test("a preferred stretch that is not tied is not chosen")
    func untiedPreferenceIsIgnored() throws {
        let profile = Self.outAndBack
        let point = CLLocationCoordinate2D(latitude: 0, longitude: 0.015)
        let plain = try #require(profile.nearestPoint(to: point))
        let preferred = try #require(profile.nearestPoint(to: point) { $0 > Self.turn * 1.9 })

        #expect(preferred.distanceAlongRoute == plain.distanceAlongRoute)
        #expect(preferred.offRouteMeters == plain.offRouteMeters)
    }

    /// The picker's positional tier asks this way only for the coordinate
    /// (#1334), so with nothing preferred a tie must go where the plain
    /// search sends it, to the start of the route.
    @Test("with nothing preferred a tie goes where the plain search sends it")
    func nothingPreferredIsThePlainSearch() throws {
        let profile = Self.outAndBack
        let plain = try #require(profile.nearestPoint(to: Self.midpoint))
        let unpreferred = try #require(profile.nearestPoint(to: Self.midpoint) { _ in false })

        #expect(unpreferred.distanceAlongRoute == plain.distanceAlongRoute)
        #expect(unpreferred.offRouteMeters == plain.offRouteMeters)
        #expect(plain.distanceAlongRoute < Self.turn)
        #expect(unpreferred.coordinate.latitude.isApproximatelyEqual(to: 0, absoluteTolerance: 1e-9))
        #expect(unpreferred.coordinate.longitude.isApproximatelyEqual(to: 0.01, absoluteTolerance: 1e-9))
    }

    @Test("the chosen coordinate stays on a stationary piece after a pause", arguments: [false, true])
    func stationaryPieceKeepsItsProjection(continuesAfterAnotherPause: Bool) throws {
        var route = [
            RouteCoordinate(latitude: 47.00005, longitude: 19),
            RouteCoordinate(latitude: 47.00005, longitude: 19.02),
            RouteCoordinate(latitude: 47, longitude: 19, boundary: .paused),
            RouteCoordinate(latitude: 47, longitude: 19),
        ]
        if continuesAfterAnotherPause {
            route += [
                RouteCoordinate(latitude: 48, longitude: 20, boundary: .paused),
                RouteCoordinate(latitude: 48, longitude: 20.02),
            ]
        }
        let profile = RouteProfile(route: route)
        let camera = CLLocationCoordinate2D(latitude: 47, longitude: 19)

        let preferred = try #require(profile.nearestPoint(to: camera, preferring: { _ in true }))

        #expect(preferred.coordinate.latitude == camera.latitude)
        #expect(preferred.coordinate.longitude == camera.longitude)
        #expect(preferred.offRouteMeters.isApproximatelyEqual(to: 0, absoluteTolerance: 1e-6))
    }
}
