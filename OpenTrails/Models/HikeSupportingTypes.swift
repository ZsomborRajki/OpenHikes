//
//  HikeSupportingTypes.swift
//  OpenTrails
//
//  Value types stored inline by SwiftData as part of a Hike, plus the
//  elevation-profile sample type derived from a route.
//

import Foundation
import CoreLocation

/// A record of one offline tile download for a hike. Stored inline by SwiftData
/// as part of ``Hike/offlineDownloads``; the parameters recompute the exact tiles.
struct OfflineDownloadRecord: Codable, Hashable {
    /// Tile provider the download used (namespaces the cache keys).
    var providerID: String
    /// Display scale the tiles were saved at (part of the cache key).
    var scale: Double
    /// Deepest zoom level saved.
    var maxZoom: Int
}

/// One point on the elevation profile: metres from start vs. elevation in metres.
///
/// Identified by its own distance rather than a per-instance `UUID`: the chart's
/// `ForEach` diffs the plotted samples by `id`, so a fresh identity per instance
/// made every rebuild of the same route diff as a wholesale replacement. Distance
/// along the route is unique within a profile (``RouteProfile`` keeps the plotted
/// samples strictly ascending) and identical across rebuilds — and free, where
/// `UUID()` was over half the cost of building a long profile.
struct ElevationSample: Identifiable, Equatable {
    var id: Double { distanceMeters }
    let distanceMeters: Double
    let elevation: Double
}

/// A single Codable track point. Stored inline by SwiftData as part of ``Hike/route``.
struct RouteCoordinate: Codable, Hashable {
    var latitude: Double
    var longitude: Double
    var elevation: Double?
    var timestamp: Date?

    nonisolated init(
        latitude: Double,
        longitude: Double,
        elevation: Double? = nil,
        timestamp: Date? = nil
    ) {
        self.latitude = latitude
        self.longitude = longitude
        self.elevation = elevation
        self.timestamp = timestamp
    }

    nonisolated init(_ coordinate: CLLocationCoordinate2D) {
        self.latitude = coordinate.latitude
        self.longitude = coordinate.longitude
    }

    nonisolated var clCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}
