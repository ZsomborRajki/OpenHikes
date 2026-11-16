//
//  WatchGeodesyProjectionTests.swift
//  OpenHikesSharedTests
//
//  A segment seen from the other side of the world (#1439), on the watch's
//  copy of the arithmetic.
//
//  The same cases `RouteGeometryProjectionTests` holds the phone's projection
//  to, for the reason `WatchGeodesy`'s header gives for there being two:
//  wrapped end by end around the fix, a segment that straddles the meridian
//  opposite the fix read as the whole world the long way round, straight
//  through the fix. `WatchGeodesyParityTests` in the app bundle holds the two
//  to the same output; these hold the watch's to the right one.
//

import Foundation
import OpenHikesShared
import RealModule
import Testing

@Suite("Watch projection from the far side of the world")
struct WatchGeodesyProjectionTests {
    /// Further than a quarter of the way round: no threshold anything
    /// compares an offset with comes near it, and every fixture below is
    /// about half the world from its segment.
    private static let farMeters = 10_000_000.0

    /// A segment 0.2° long running east across ±180°, on the equator.
    private static func seamProjection(fromLongitude longitude: Double) -> WatchGeodesy.SegmentProjection {
        WatchGeodesy.project(
            latitude: 0,
            longitude: longitude,
            onSegmentFromLatitude: 0,
            longitude: 179.9,
            toLatitude: 0,
            longitude: -179.9
        )
    }

    @Test("A segment across the antimeridian is still under a fix at the seam")
    func seamSegmentNearTheSeam() {
        let projection = Self.seamProjection(fromLongitude: 180)

        #expect(projection.offRouteMeters.isApproximatelyEqual(to: 0, absoluteTolerance: 0.01))
        #expect(projection.fraction.isApproximatelyEqual(to: 0.5, absoluteTolerance: 1e-6))
    }

    @Test("A segment across the antimeridian is half a world from a fix at Greenwich")
    func seamSegmentFromGreenwich() {
        #expect(Self.seamProjection(fromLongitude: 0).offRouteMeters > Self.farMeters)
    }

    /// The defect is about the fix, not about ±180°: any segment straddles
    /// the meridian opposite a fix somewhere. This one sits off the equator,
    /// and the fix is off the antimeridian, so neither is a special value.
    @Test("An ordinary segment is half a world from a fix near its opposite meridian")
    func ordinarySegmentFromItsOppositeMeridian() {
        let projection = WatchGeodesy.project(
            latitude: 10,
            longitude: -179.97,
            onSegmentFromLatitude: 10,
            longitude: 0,
            toLatitude: 10,
            longitude: 0.1
        )

        #expect(projection.offRouteMeters > Self.farMeters)
    }

    /// The tracker's tie-break reads the bearing as the way the trail runs.
    /// Wrapped end by end, a segment seen from the far side pointed the long
    /// way round, west.
    @Test("A segment runs its short way, east, wherever it is seen from")
    func directionIsTheShortWay() {
        for longitude in [180.0, 0] {
            let projection = Self.seamProjection(fromLongitude: longitude)

            #expect(
                projection.bearingDegrees.isApproximatelyEqual(to: 90, absoluteTolerance: 1e-6),
                "seen from \(longitude)°"
            )
            #expect(projection.dx < 25_000, "seen from \(longitude)°")
        }
    }
}
