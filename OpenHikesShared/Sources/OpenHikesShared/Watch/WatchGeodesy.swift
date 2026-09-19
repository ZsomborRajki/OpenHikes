//
//  WatchGeodesy.swift
//  OpenHikesShared
//
//  Great-circle distance and tangent-plane projection on plain `Double`s, for
//  the watch app — which has to match a fix against a trail and accumulate a
//  walk's distance, and cannot reach the app's `RouteGeometry` to do either.
//
//  ## Why this is a second copy rather than a shared one
//
//  `RouteGeometry` lives in the app target and is written against
//  `CLLocationCoordinate2D`. This package deliberately imports no Core
//  Location — it is read by the widget extension off the main actor and by a
//  watch app that projects points it was handed as numbers — so the app's
//  spelling cannot simply be moved here without dragging the framework along
//  with it.
//
//  Making the app's version delegate to this one *was* the other option, and
//  it was turned down on where it would be paid: `RouteGeometry.distanceMeters`
//  is called once per route point while `RouteProfile` is built, which is
//  every point of a twenty-thousand-point import, and a cross-module call is
//  not reliably inlined. So this is the same trade `Color+Hex` already makes —
//  see *Claims investigated and found false* in the repository instructions —
//  and it is paid for the same way: `WatchGeodesyParityTests` in the app
//  bundle holds the two implementations to identical output on fixtures, so a
//  constant changed in one and not the other fails a gate rather than
//  quietly moving a trail.
//
//  The earth radius is deliberately the same literal as `RouteGeometry`'s, and
//  is the number the parity test is really guarding.
//

import Foundation

public enum WatchGeodesy {
    /// IUGG mean earth radius, the same figure `RouteGeometry` uses.
    public static let earthRadiusMeters = 6_371_008.8

    /// Great-circle distance in metres, without allocating anything per leg.
    public static func distanceMeters(
        fromLatitude startLatitude: Double,
        longitude startLongitude: Double,
        toLatitude endLatitude: Double,
        longitude endLongitude: Double
    ) -> Double {
        let startRadians = startLatitude * .pi / 180
        let endRadians = endLatitude * .pi / 180
        let latitudeDelta = (endLatitude - startLatitude) * .pi / 180
        let longitudeDelta = normalizedLongitudeDelta(
            endLongitude - startLongitude
        ) * .pi / 180
        let latitudeTerm = sin(latitudeDelta / 2)
        let longitudeTerm = sin(longitudeDelta / 2)
        let haversine = latitudeTerm * latitudeTerm
            + cos(startRadians) * cos(endRadians) * longitudeTerm * longitudeTerm
        let bounded = min(max(haversine, 0), 1)
        return 2 * earthRadiusMeters * atan2(sqrt(bounded), sqrt(1 - bounded))
    }

    /// Local tangent-plane offset in metres, east and north of `origin`.
    ///
    /// Accurate enough for projecting a fix onto nearby trail segments, and it
    /// keeps the *short* direction across the antimeridian — which plain
    /// subtraction does not, and which is wrong every time a trail crosses
    /// ±180°.
    public static func localOffset(
        fromLatitude originLatitude: Double,
        longitude originLongitude: Double,
        toLatitude latitude: Double,
        longitude: Double
    ) -> (x: Double, y: Double) {
        let originRadians = originLatitude * .pi / 180
        let longitudeDelta = normalizedLongitudeDelta(longitude - originLongitude)
        return (
            x: longitudeDelta * .pi / 180 * earthRadiusMeters * cos(originRadians),
            y: (latitude - originLatitude) * .pi / 180 * earthRadiusMeters
        )
    }

    /// Where a fix falls on one segment, measured in the fix's own tangent
    /// plane so the projection is exact at the point that matters.
    ///
    /// The same shape as `RouteGeometry.SegmentProjection`, and deliberately
    /// so: the two are held to identical output by `WatchGeodesyParityTests`.
    public struct SegmentProjection: Equatable, Sendable {
        /// How far along the segment the closest point sits, clamped to
        /// `0...1` so a fix beyond either end projects onto that end rather
        /// than onto the segment's infinite extension.
        public let fraction: Double
        /// Distance from the fix to that closest point, in metres.
        public let offRouteMeters: Double
        /// The segment's local east/north components, pointing the way the
        /// segment runs. Kept as components rather than as a bearing so the
        /// `atan2` is paid only by the caller that needs a direction, not by
        /// every segment scanned on every fix.
        public let dx: Double
        public let dy: Double

        /// The way the segment runs, in degrees clockwise from north — the
        /// same convention `CLLocation.course` reports in.
        public var bearingDegrees: Double { atan2(dx, dy) * 180 / .pi }
    }

    /// Projects a coordinate onto the segment between two others.
    public static func project(
        latitude: Double,
        longitude: Double,
        onSegmentFromLatitude startLatitude: Double,
        longitude startLongitude: Double,
        toLatitude endLatitude: Double,
        longitude endLongitude: Double
    ) -> SegmentProjection {
        let start = localOffset(
            fromLatitude: latitude,
            longitude: longitude,
            toLatitude: startLatitude,
            longitude: startLongitude
        )
        let end = localOffset(
            fromLatitude: latitude,
            longitude: longitude,
            toLatitude: endLatitude,
            longitude: endLongitude
        )
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        let fraction = lengthSquared > 0
            ? min(max(-(start.x * dx + start.y * dy) / lengthSquared, 0), 1)
            : 0
        return SegmentProjection(
            fraction: fraction,
            offRouteMeters: hypot(start.x + fraction * dx, start.y + fraction * dy),
            dx: dx,
            dy: dy
        )
    }

    /// Brings a longitude difference back into `-180...180`, so two points
    /// either side of the antimeridian read as neighbours rather than as
    /// opposite ends of the world.
    public static func normalizedLongitudeDelta(_ delta: Double) -> Double {
        var normalized = delta.truncatingRemainder(dividingBy: 360)
        if normalized > 180 { normalized -= 360 }
        if normalized < -180 { normalized += 360 }
        return normalized
    }
}
