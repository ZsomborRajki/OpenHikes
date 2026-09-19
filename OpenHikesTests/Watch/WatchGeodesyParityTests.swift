//
//  WatchGeodesyParityTests.swift
//  OpenHikesTests
//
//  Holds `WatchGeodesy` and `RouteGeometry` to identical output.
//
//  The two are the same arithmetic written twice, for the reason
//  `WatchGeodesy`'s header gives — the shared package imports no Core Location,
//  and the app's version is on a per-route-point path where a cross-module
//  call is not reliably inlined. That is the same trade `Color+Hex` makes, and
//  it is paid the same way: this is `ColorHexTests` for the geometry.
//
//  What it is really guarding is the earth radius. A constant changed in one
//  and not the other moves every trail on the watch by a fraction of a
//  percent — enough to make a 20 km trail disagree with the phone by a hundred
//  metres, and nothing in either build would say so.
//
//  Exact equality rather than a tolerance, deliberately. These are not two
//  approximations of one quantity that happen to be close; they are the same
//  expression in the same order on the same doubles, and any difference at all
//  means one of them has been edited.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesShared
import Testing

@Suite("Watch geodesy parity")
struct WatchGeodesyParityTests {
    @Test("the two distance functions agree exactly", arguments: Fixture.pairs)
    func distancesAgree(pair: Fixture.Pair) {
        let app = RouteGeometry.distanceMeters(from: pair.start, to: pair.end)
        let watch = WatchGeodesy.distanceMeters(
            fromLatitude: pair.start.latitude,
            longitude: pair.start.longitude,
            toLatitude: pair.end.latitude,
            longitude: pair.end.longitude
        )
        #expect(app == watch)
    }

    @Test("the two tangent-plane offsets agree exactly", arguments: Fixture.pairs)
    func offsetsAgree(pair: Fixture.Pair) {
        let app = RouteGeometry.localOffset(from: pair.start, to: pair.end)
        let watch = WatchGeodesy.localOffset(
            fromLatitude: pair.start.latitude,
            longitude: pair.start.longitude,
            toLatitude: pair.end.latitude,
            longitude: pair.end.longitude
        )
        #expect(app.x == watch.x)
        #expect(app.y == watch.y)
    }

    @Test("the two segment projections agree exactly", arguments: Fixture.pairs)
    func projectionsAgree(pair: Fixture.Pair) {
        let app = RouteGeometry.project(
            pair.fix,
            onSegmentFrom: pair.start,
            to: pair.end
        )
        let watch = WatchGeodesy.project(
            latitude: pair.fix.latitude,
            longitude: pair.fix.longitude,
            onSegmentFromLatitude: pair.start.latitude,
            longitude: pair.start.longitude,
            toLatitude: pair.end.latitude,
            longitude: pair.end.longitude
        )
        #expect(app.fraction == watch.fraction)
        #expect(app.offRouteMeters == watch.offRouteMeters)
        #expect(app.dx == watch.dx)
        #expect(app.dy == watch.dy)
    }

    @Test("the earth radius is one number in two files")
    func theRadiusIsTheSame() {
        // Not reachable through `RouteGeometry` — the constant is private
        // there — so this is asserted against the literal the app's file
        // carries. Changing it in one place makes the three tests above fail
        // whatever this one says; this one is here so the *reason* is in the
        // failure list rather than only in a pile of unequal doubles.
        #expect(WatchGeodesy.earthRadiusMeters == 6_371_008.8)
    }

    nonisolated enum Fixture {
        struct Pair: Sendable, CustomTestStringConvertible {
            let name: String
            let start: CLLocationCoordinate2D
            let end: CLLocationCoordinate2D
            /// A point to project onto the segment. Off to one side, so
            /// `fraction` is interesting rather than 0 or 1.
            let fix: CLLocationCoordinate2D

            var testDescription: String { name }
        }

        nonisolated static let pairs: [Pair] = [
            Pair(
                name: "a short alpine leg",
                start: CLLocationCoordinate2D(latitude: 47.5500, longitude: 12.9000),
                end: CLLocationCoordinate2D(latitude: 47.5510, longitude: 12.9020),
                fix: CLLocationCoordinate2D(latitude: 47.5504, longitude: 12.9014)
            ),
            Pair(
                name: "a leg crossing the equator",
                start: CLLocationCoordinate2D(latitude: -0.0100, longitude: 36.8000),
                end: CLLocationCoordinate2D(latitude: 0.0100, longitude: 36.8200),
                fix: CLLocationCoordinate2D(latitude: 0.0020, longitude: 36.8090)
            ),
            // The case plain subtraction gets wrong, which is why both
            // implementations normalise the longitude difference.
            Pair(
                name: "a leg crossing the antimeridian",
                start: CLLocationCoordinate2D(latitude: -17.7000, longitude: 179.9500),
                end: CLLocationCoordinate2D(latitude: -17.7100, longitude: -179.9500),
                fix: CLLocationCoordinate2D(latitude: -17.7040, longitude: 179.9900)
            ),
            Pair(
                name: "a far-northern leg, where the cosine term bites",
                start: CLLocationCoordinate2D(latitude: 78.2200, longitude: 15.6300),
                end: CLLocationCoordinate2D(latitude: 78.2300, longitude: 15.7000),
                fix: CLLocationCoordinate2D(latitude: 78.2280, longitude: 15.6500)
            ),
            // A degenerate segment: both ends the same place, which is the
            // branch where the projection divides by a zero length.
            Pair(
                name: "a segment of no length",
                start: CLLocationCoordinate2D(latitude: 47.5500, longitude: 12.9000),
                end: CLLocationCoordinate2D(latitude: 47.5500, longitude: 12.9000),
                fix: CLLocationCoordinate2D(latitude: 47.5510, longitude: 12.9010)
            ),
        ]
    }
}
