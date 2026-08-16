//
//  HikeSupportingTypes.swift
//  OpenHikes
//
//  Value types stored inline by SwiftData as part of a Hike, the
//  elevation-profile sample type derived from a route, and the coordinate
//  geometry every route-matching path shares.
//

import CoreLocation
import Foundation

/// A record of one offline tile download for a hike. Stored inline by SwiftData
/// as part of ``Hike/offlineDownloads``. Complete downloads stay compact by
/// recomputing their tile grid; partial downloads record only the keys that
/// actually reached durable storage.
nonisolated struct OfflineDownloadRecord: Codable, Hashable, Sendable {
    /// Tile provider the download used (namespaces the cache keys).
    var providerID: String
    /// Display scale the tiles were saved at (part of the cache key).
    var scale: Double
    /// Deepest zoom level saved.
    var maxZoom: Int
    /// Exact durable keys for a partial download. An empty array indicates
    /// that every tile in the deterministic grid was saved (complete download).
    var savedTileKeys: [String]

    init(providerID: String, scale: Double, maxZoom: Int, savedTileKeys: [String] = []) {
        self.providerID = providerID
        self.scale = scale
        self.maxZoom = maxZoom
        self.savedTileKeys = savedTileKeys
    }
}

/// One point on the elevation profile: metres from start vs. elevation in metres.
///
/// Identified by its own distance rather than a per-instance `UUID`: the chart's
/// `ForEach` diffs the plotted samples by `id`, so a fresh identity per instance
/// made every rebuild of the same route diff as a wholesale replacement. Distance
/// along the route is unique within a profile (``RouteProfile`` keeps the plotted
/// samples strictly ascending) and identical across rebuilds — and costs nothing
/// to derive, where `UUID()` is allocated per sample.
nonisolated struct ElevationSample: Identifiable, Equatable, Sendable {
    var id: Double { distanceMeters }
    let distanceMeters: Double
    let elevation: Double
}

/// How a fix was moving, where Core Motion judged it was not on foot.
///
/// **Collected but not yet read.** ``RecordingModels`` tags a fix
/// `.nonPedestrian` when Core Motion reports automotive, cycling or an
/// otherwise non-walking activity, and it is persisted with the route — but no
/// statistic, chart, breakdown or export consults it today.
///
/// That is deliberate rather than an oversight. The intended use is flagging
/// or excluding vehicle-assisted segments (a chairlift, a shuttle bus, the
/// drive to a second trailhead), which distorts distance, pace and ascent
/// figures for anyone whose walk included one. Recording it now means the
/// feature can be built against hikes people have *already* recorded, where
/// dropping the field would make every existing route permanently unusable
/// for it — Core Motion's judgement cannot be reconstructed after the fact.
///
/// One `String?` per track point is a cheap option to hold open. Do not remove
/// it as unused: an unused-symbol sweep is right about the reads and wrong
/// about the reason.
nonisolated enum RouteMotion: String, Codable, Hashable, Sendable {
    case nonPedestrian = "nonPedestrian"
}

/// A single Codable track point. Stored inline by SwiftData as part of ``Hike/route``.
nonisolated struct RouteCoordinate: Codable, Hashable, Sendable {
    var latitude: Double
    var longitude: Double
    var elevation: Double?
    var timestamp: Date?
    /// Recorded for a future feature, read by nothing today — see
    /// ``RouteMotion``.
    var motion: RouteMotion?

    init(
        latitude: Double,
        longitude: Double,
        elevation: Double? = nil,
        timestamp: Date? = nil,
        motion: RouteMotion? = nil
    ) {
        self.latitude = latitude
        self.longitude = longitude
        self.elevation = elevation
        self.timestamp = timestamp
        self.motion = motion
    }

    init(_ coordinate: CLLocationCoordinate2D) {
        latitude = coordinate.latitude
        longitude = coordinate.longitude
        motion = nil
    }

    var clCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

nonisolated enum RouteGeometry {
    private static let earthRadiusMeters = 6_371_008.8

    /// Great-circle distance without allocating Core Location objects per leg.
    static func distanceMeters(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D
    ) -> Double {
        let startLatitude = start.latitude * .pi / 180
        let endLatitude = end.latitude * .pi / 180
        let latitudeDelta = (end.latitude - start.latitude) * .pi / 180
        let longitudeDelta = normalizedLongitudeDelta(end.longitude - start.longitude) * .pi / 180
        let latitudeTerm = sin(latitudeDelta / 2)
        let longitudeTerm = sin(longitudeDelta / 2)
        let haversine = latitudeTerm * latitudeTerm
            + cos(startLatitude) * cos(endLatitude) * longitudeTerm * longitudeTerm
        let bounded = min(max(haversine, 0), 1)
        return 2 * earthRadiusMeters * atan2(sqrt(bounded), sqrt(1 - bounded))
    }

    /// Local tangent-plane offset in metres. Accurate enough for projecting a
    /// fix onto nearby trail segments, while preserving the short direction
    /// across the antimeridian.
    static func localOffset(
        from origin: CLLocationCoordinate2D,
        to coordinate: CLLocationCoordinate2D
    ) -> (x: Double, y: Double) {
        let latitudeRadians = origin.latitude * .pi / 180
        let longitudeDelta = normalizedLongitudeDelta(
            coordinate.longitude - origin.longitude
        )
        return (
            x: longitudeDelta * .pi / 180
                * earthRadiusMeters * cos(latitudeRadians),
            y: (coordinate.latitude - origin.latitude) * .pi / 180
                * earthRadiusMeters
        )
    }

    /// Where a fix falls on one segment, measured in the fix's own tangent
    /// plane so the projection is exact at the point that matters.
    struct SegmentProjection {
        /// How far along the segment the closest point sits, clamped to
        /// `0...1` so a fix beyond either end projects onto that end rather
        /// than onto the segment's infinite extension.
        let fraction: Double
        /// Distance from the fix to that closest point, in metres.
        let offRouteMeters: Double
        /// The segment's local east/north components, pointing the way the
        /// segment runs. Kept as components rather than a bearing so the
        /// `atan2` is paid only by the callers that need a direction, not by
        /// every segment scanned on every published fix.
        let dx: Double
        let dy: Double
    }

    /// Projects `coordinate` onto the segment between `start` and `end`.
    ///
    /// Live auto-follow (``RouteProfile``), trail matching, and surface and
    /// difficulty attribution all need the same answer. One implementation
    /// means a fix can't be judged on-route by one of them and off-route by
    /// another.
    static func project(
        _ coordinate: CLLocationCoordinate2D,
        onSegmentFrom start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D
    ) -> SegmentProjection {
        let startOffset = localOffset(from: coordinate, to: start)
        let endOffset = localOffset(from: coordinate, to: end)
        let dx = endOffset.x - startOffset.x
        let dy = endOffset.y - startOffset.y
        let lengthSquared = dx * dx + dy * dy
        let fraction = lengthSquared > 0
            ? min(
                max(
                    -(startOffset.x * dx + startOffset.y * dy) / lengthSquared,
                    0
                ),
                1
            )
            : 0
        return SegmentProjection(
            fraction: fraction,
            offRouteMeters: hypot(
                startOffset.x + fraction * dx,
                startOffset.y + fraction * dy
            ),
            dx: dx,
            dy: dy
        )
    }

    static func interpolate(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D,
        fraction: Double
    ) -> CLLocationCoordinate2D {
        let bounded = min(max(fraction, 0), 1)
        let longitude = start.longitude
            + normalizedLongitudeDelta(end.longitude - start.longitude)
                * bounded
        return CLLocationCoordinate2D(
            latitude: start.latitude
                + (end.latitude - start.latitude) * bounded,
            longitude: normalizedLongitude(longitude)
        )
    }

    static func normalizedLongitudeDelta(_ delta: Double) -> Double {
        var normalized = delta.truncatingRemainder(dividingBy: 360)
        if normalized > 180 { normalized -= 360 }
        if normalized < -180 { normalized += 360 }
        return normalized
    }

    static func normalizedLongitude(_ longitude: Double) -> Double {
        var normalized = longitude.truncatingRemainder(dividingBy: 360)
        if normalized >= 180 { normalized -= 360 }
        if normalized < -180 { normalized += 360 }
        return normalized
    }
}
