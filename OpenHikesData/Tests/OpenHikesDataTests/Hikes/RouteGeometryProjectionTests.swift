//
//  RouteGeometryProjectionTests.swift
//  OpenHikesDataTests
//
//  A segment seen from the other side of the world (#1439).
//
//  ``RouteGeometry/project(_:onSegmentFrom:to:)`` measures in the fix's own
//  tangent plane, and wraps each end's longitude the short way round the fix.
//  A segment that straddles the meridian opposite the fix had its two ends
//  wrapped to opposite edges of that plane, so it read as the whole world the
//  long way round — straight through the fix, at no distance at all. That is
//  as true of a trail at Greenwich seen from the antimeridian as of one across
//  the antimeridian seen from Greenwich.
//
//  The antimeridian cases in `RouteProfileTests+Matching` query a fix beside
//  the real segment; these query its false world-spanning copy as well. The
//  watch's copy of the arithmetic is held to the same cases by
//  `WatchGeodesyProjectionTests`, and to the same output by
//  `WatchGeodesyParityTests`.
//

import CoreLocation
import Foundation
@testable import OpenHikesData
import RealModule
import Testing

@Suite("Projection from the far side of the world")
struct RouteGeometryProjectionTests {
    /// Further than a quarter of the way round: no threshold anything
    /// compares an offset with comes near it, and every fixture below is
    /// about half the world from its segment.
    private static let farMeters = 10_000_000.0

    /// A segment 0.2° long running east across ±180°.
    private static let seamStart = CLLocationCoordinate2D(latitude: 0, longitude: 179.9)
    private static let seamEnd = CLLocationCoordinate2D(latitude: 0, longitude: -179.9)

    @Test("a segment across the antimeridian is still under a fix at the seam")
    func seamSegmentNearTheSeam() {
        let projection = RouteGeometry.project(
            CLLocationCoordinate2D(latitude: 0, longitude: 180),
            onSegmentFrom: Self.seamStart,
            to: Self.seamEnd
        )

        #expect(projection.offRouteMeters.isApproximatelyEqual(to: 0, absoluteTolerance: 0.01))
        #expect(projection.fraction.isApproximatelyEqual(to: 0.5, absoluteTolerance: 1e-6))
    }

    @Test("a segment across the antimeridian is half a world from a fix at Greenwich")
    func seamSegmentFromGreenwich() {
        let projection = RouteGeometry.project(
            CLLocationCoordinate2D(latitude: 0, longitude: 0),
            onSegmentFrom: Self.seamStart,
            to: Self.seamEnd
        )

        #expect(projection.offRouteMeters > Self.farMeters)
    }

    /// The defect is about the fix, not about ±180°: any segment straddles
    /// the meridian opposite a fix somewhere. This one sits off the equator,
    /// and the fix is off the antimeridian, so neither is a special value.
    @Test("an ordinary segment is half a world from a fix near its opposite meridian")
    func ordinarySegmentFromItsOppositeMeridian() {
        let projection = RouteGeometry.project(
            CLLocationCoordinate2D(latitude: 10, longitude: -179.97),
            onSegmentFrom: CLLocationCoordinate2D(latitude: 10, longitude: 0),
            to: CLLocationCoordinate2D(latitude: 10, longitude: 0.1)
        )

        #expect(projection.offRouteMeters > Self.farMeters)
    }

    /// A segment's components are its direction, which the tie-breaks read
    /// as the way the trail runs. Wrapped end by end, a segment seen from
    /// the far side pointed the long way round, west.
    @Test("a segment runs its short way wherever it is seen from")
    func directionIsTheShortWay() {
        for fix in [
            CLLocationCoordinate2D(latitude: 0, longitude: 180),
            CLLocationCoordinate2D(latitude: 0, longitude: 0),
        ] {
            let projection = RouteGeometry.project(fix, onSegmentFrom: Self.seamStart, to: Self.seamEnd)

            #expect(projection.dx > 0, "seen from \(fix.longitude)°")
            #expect(projection.dx < 25_000, "seen from \(fix.longitude)°")
        }
    }

    /// What the projection is for: the whole-route search that following a
    /// trail starts from, which must not put a hiker half a world away on it.
    @Test("a trail across the antimeridian does not match a fix at Greenwich")
    func wholeRouteSearchFromGreenwich() throws {
        let profile = RouteProfile(route: [Self.seamStart, Self.seamEnd].map(RouteCoordinate.init))
        let match = try #require(profile.nearestPoint(to: CLLocationCoordinate2D(latitude: 0, longitude: 0)))

        #expect(match.offRouteMeters > RouteProfile.followMatchThresholdMeters)
    }
}
