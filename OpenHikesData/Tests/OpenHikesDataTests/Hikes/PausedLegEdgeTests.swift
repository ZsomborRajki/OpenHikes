//
//  PausedLegEdgeTests.swift
//  OpenHikesDataTests
//
//  The paused-leg rule (#962) at the edges where the readings of it used to
//  disagree without anything saying so (#1035): a lone fix between two
//  pauses, a pause on a route's first or last leg, a route made of nothing
//  but lone fixes, and routes of one point or none.
//
//  Every consumer here reads the rule through ``TrailRuns``. What each one
//  does with a lone fix is its own decision, and these pin it: the profile
//  and a place's anchor match nothing onto one, so a place beside it goes to
//  the nearest walked leg, and a route of lone fixes alone anchors nothing.
//

import CoreLocation
import Foundation
@testable import OpenHikesData
import RealModule
import Testing

// swiftlint:disable no_magic_numbers

@Suite("The paused-leg rule at its edges")
struct PausedLegEdgeTests {
    /// One thousandth of a degree of longitude on the equator.
    private static let step = RouteGeometry.distanceMeters(
        from: CLLocationCoordinate2D(latitude: 0, longitude: 0),
        to: CLLocationCoordinate2D(latitude: 0, longitude: 0.001)
    )

    /// Points along the equator, `longitudes` in thousandths of a degree, the
    /// ones named in `resumed` arriving after a pause.
    private static func route(
        _ longitudes: [Double],
        resumingAt resumed: Set<Int>,
        elevations: [Double?] = []
    ) -> [RouteCoordinate] {
        longitudes.enumerated().map { index, longitude in
            RouteCoordinate(
                latitude: 0,
                longitude: longitude / 1000,
                elevation: elevations.isEmpty ? nil : elevations[index],
                boundary: resumed.contains(index) ? .paused : nil
            )
        }
    }

    private static func at(_ longitude: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: 0, longitude: longitude / 1000)
    }

    private static func place(at longitude: Double) -> TrailPlace {
        TrailPlace(latitude: 0, longitude: longitude / 1000, name: "Bench")
    }

    /// Walked from 0 to 1, a lone fix at 6 with a pause either side of it,
    /// then walked from 9 to 10.
    private static let loneFix = route([0, 1, 6, 9, 10], resumingAt: [2, 3])

    // MARK: - The route profile

    @Test("the profile matches nothing onto a lone fix, so a fix there goes to the nearest walked leg")
    func profileMatchesNothingOntoALoneFix() throws {
        let profile = RouteProfile(route: Self.loneFix)

        #expect(profile.totalDistanceMeters.isApproximatelyEqual(to: 2 * Self.step, absoluteTolerance: 0.01))
        let match = try #require(profile.nearestPoint(to: Self.at(6)))
        #expect(match.offRouteMeters.isApproximatelyEqual(to: 3 * Self.step, absoluteTolerance: 0.01))
        #expect(match.distanceAlongRoute > Self.step, "on the piece after the pauses, past the join")
    }

    @Test("a pause on the first or the last leg leaves that end's fix unmatched")
    func pausesOnTheEndLegsLeaveTheirFixUnmatched() throws {
        let profile = RouteProfile(route: Self.route([0, 5, 6, 7, 12], resumingAt: [1, 4]))

        #expect(profile.totalDistanceMeters.isApproximatelyEqual(to: 2 * Self.step, absoluteTolerance: 0.01))
        let first = try #require(profile.nearestPoint(to: Self.at(0)))
        #expect(first.offRouteMeters.isApproximatelyEqual(to: 5 * Self.step, absoluteTolerance: 0.01))
        let last = try #require(profile.nearestPoint(to: Self.at(12)))
        #expect(last.offRouteMeters.isApproximatelyEqual(to: 5 * Self.step, absoluteTolerance: 0.01))
    }

    @Test("a route of lone fixes has no length and nothing to match")
    func loneFixesAloneMatchNothing() {
        let profile = RouteProfile(route: Self.route([0, 10, 20], resumingAt: [1, 2]))

        #expect(profile.totalDistanceMeters == 0)
        #expect(profile.nearestPoint(to: Self.at(10)) == nil)
    }

    @Test("a pause named on the first point opens no leg")
    func pauseOnTheFirstPointIsIgnored() {
        let route = Self.route([0, 1, 2], resumingAt: [0])

        #expect(RouteProfile(route: route).totalDistanceMeters.isApproximatelyEqual(
            to: 2 * Self.step,
            absoluteTolerance: 0.01
        ))
        #expect(route.pausedSegments.isEmpty)
    }

    // MARK: - A place's anchor

    @Test("a place on a lone fix anchors to the nearest walked leg, not to the fix")
    func placeOnALoneFixAnchorsToAWalkedLeg() throws {
        let bench = Self.place(at: 6)

        let anchor = try #require(TrailPlaceOrder.anchors(of: [bench], along: Self.loneFix)[bench.id])

        #expect(anchor.offRouteMeters.isApproximatelyEqual(to: 3 * Self.step, absoluteTolerance: 0.01))
        #expect(anchor.distanceAlongRouteMeters.isApproximatelyEqual(to: Self.step, absoluteTolerance: 0.01))
    }

    @Test("a route of lone fixes, or of one point, anchors nothing")
    func loneFixesAloneAnchorNothing() {
        let bench = Self.place(at: 10)

        #expect(TrailPlaceOrder.anchors(of: [bench], along: Self.route([0, 10, 20], resumingAt: [1, 2])).isEmpty)
        #expect(TrailPlaceOrder.anchors(of: [bench], along: Self.route([10], resumingAt: [])).isEmpty)
        #expect(TrailPlaceOrder.anchors(of: [bench], along: []).isEmpty)
    }

    // MARK: - The map's paused lines

    @Test("adjacent pauses are a line each, from the fix before to the fix after")
    func adjacentPausesAreALineEach() {
        let lines = Self.loneFix.pausedSegments

        #expect(lines.count == 2)
        #expect(lines.map { $0.map(\.longitude) } == [[0.001, 0.006], [0.006, 0.009]])
    }

    // MARK: - Heights

    @Test("a lone fix's height has no neighbours to be a spike between")
    func loneFixIsNeverASpike() {
        let route = Self.route(
            [0, 0.1, 0.2, 0.3, 0.4],
            resumingAt: [2, 3],
            elevations: [1000, 1000, 0, 1000, 1000]
        )

        #expect(PlausibleElevation.despiked(route) == route)
    }
}

// swiftlint:enable no_magic_numbers
