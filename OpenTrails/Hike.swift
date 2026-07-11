//
//  Hike.swift
//  OpenTrails
//
//  A recorded or imported hike, persisted with SwiftData and backing the Hikes list.
//

import SwiftUI
import SwiftData
import CoreLocation
import MapKit
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@Model
final class Hike {
    /// Stable identity, also used to key the route drawn on the map.
    var id: UUID
    var title: String
    /// Total route length, in meters.
    var distanceMeters: Double
    /// Activity date — the GPX start time when available, otherwise the import date.
    var date: Date
    /// Route tint, stored as "#RRGGBB" or "#RRGGBBAA". The alpha is used only for
    /// the map polyline; other UI reads ``tintOpaque``.
    var tintHex: String
    /// Map polyline width, in points.
    var routeWidth: Double
    /// SF Symbol shown in the row's colored circle.
    var symbol: String
    /// Ordered track points making up the route.
    var route: [RouteCoordinate]

    /// Records of offline tile downloads for this hike, enough to recompute (and
    /// so measure and remove) exactly the tiles each one saved.
    var offlineDownloads: [OfflineDownloadRecord]

    // Optional metadata pulled from the GPX file.
    var trackDescription: String?
    var author: String?
    var keywords: String?

    init(
        id: UUID = UUID(),
        title: String,
        distanceMeters: Double,
        date: Date = .now,
        tintHex: String = "#34C759",
        routeWidth: Double = 5,
        symbol: String = "figure.hiking",
        route: [RouteCoordinate] = [],
        offlineDownloads: [OfflineDownloadRecord] = [],
        trackDescription: String? = nil,
        author: String? = nil,
        keywords: String? = nil
    ) {
        self.id = id
        self.title = title
        self.distanceMeters = distanceMeters
        self.date = date
        self.tintHex = tintHex
        self.routeWidth = routeWidth
        self.symbol = symbol
        self.route = route
        self.offlineDownloads = offlineDownloads
        self.trackDescription = trackDescription
        self.author = author
        self.keywords = keywords
    }
}

// MARK: - Presentation helpers

extension Hike {
    var distance: Measurement<UnitLength> {
        Measurement(value: distanceMeters, unit: .meters)
    }

    /// Full tint including the user's chosen alpha — used for the map polyline.
    var tint: Color { Color(hex: tintHex) ?? .green }

    /// Tint forced fully opaque — used everywhere except the map line (graph,
    /// list-row circle, header icon, highlight dot), so transparency reads only
    /// on the route itself.
    var tintOpaque: Color { tint.opaque }

    /// "5.2 km · Jun 12, 2026" — length and record/import date.
    var subtitle: String {
        let length = distance.formatted(
            .measurement(width: .abbreviated, usage: .road)
        )
        let day = date.formatted(date: .abbreviated, time: .omitted)
        return "\(length) · \(day)"
    }

    var coordinates: [CLLocationCoordinate2D] {
        route.map(\.clCoordinate)
    }
}

// MARK: - Derived statistics

extension Hike {
    var pointCount: Int { route.count }

    var elevations: [Double] { route.compactMap(\.elevation) }
    var timestamps: [Date] { route.compactMap(\.timestamp) }

    var startDate: Date? { timestamps.first }
    var endDate: Date? { timestamps.last }

    /// Elapsed time between the first and last timestamped points.
    var duration: TimeInterval? {
        guard let start = startDate, let end = endDate, end > start else { return nil }
        return end.timeIntervalSince(start)
    }

    var maxElevation: Measurement<UnitLength>? {
        elevations.max().map { Measurement(value: $0, unit: .meters) }
    }

    var minElevation: Measurement<UnitLength>? {
        elevations.min().map { Measurement(value: $0, unit: .meters) }
    }

    /// Cumulative climb over all points (sum of positive elevation deltas).
    var elevationGain: Measurement<UnitLength>? {
        elevationDelta(positive: true)
    }

    /// Cumulative descent over all points (sum of negative elevation deltas).
    var elevationLoss: Measurement<UnitLength>? {
        elevationDelta(positive: false)
    }

    private func elevationDelta(positive: Bool) -> Measurement<UnitLength>? {
        let e = elevations
        guard e.count > 1 else { return nil }
        var total = 0.0
        for i in 1..<e.count {
            let d = e[i] - e[i - 1]
            if (positive && d > 0) || (!positive && d < 0) { total += abs(d) }
        }
        return Measurement(value: total, unit: .meters)
    }

    /// Distance ÷ moving time.
    var averageSpeed: Measurement<UnitSpeed>? {
        guard let duration, duration > 0 else { return nil }
        return Measurement(value: distanceMeters / duration, unit: .metersPerSecond)
    }

    /// Fastest instantaneous pace between two consecutive timestamped points.
    var maxSpeed: Measurement<UnitSpeed>? {
        guard route.count > 1 else { return nil }
        var best = 0.0
        for i in 1..<route.count {
            guard let t0 = route[i - 1].timestamp, let t1 = route[i].timestamp else { continue }
            let dt = t1.timeIntervalSince(t0)
            guard dt > 0 else { continue }
            let a = CLLocation(latitude: route[i - 1].latitude, longitude: route[i - 1].longitude)
            let b = CLLocation(latitude: route[i].latitude, longitude: route[i].longitude)
            best = max(best, b.distance(from: a) / dt)
        }
        return best > 0 ? Measurement(value: best, unit: .metersPerSecond) : nil
    }
}

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
struct ElevationSample: Identifiable {
    let id = UUID()
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

extension Color {
    /// The resolved sRGB components (0…1) of this color.
    private var rgba: (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) {
        #if canImport(UIKit)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        return (r, g, b, a)
        #else
        let c = NSColor(self).usingColorSpace(.sRGB) ?? .black
        return (c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent)
        #endif
    }

    /// "#RRGGBBAA" for the resolved color — the inverse of `init?(hex:)`, used to
    /// persist a picked color (with its alpha) back into `Hike.tintHex`.
    var hexRGBA: String {
        let c = rgba
        return String(
            format: "#%02X%02X%02X%02X",
            Int((c.r * 255).rounded()), Int((c.g * 255).rounded()),
            Int((c.b * 255).rounded()), Int((c.a * 255).rounded())
        )
    }

    /// The same color forced fully opaque (alpha = 1).
    var opaque: Color {
        let c = rgba
        return Color(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: 1)
    }

    /// Parses "#RRGGBB" or "#RRGGBBAA" (with or without the leading `#`).
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard let value = UInt32(s, radix: 16) else { return nil }
        switch s.count {
        case 6:
            self.init(
                .sRGB,
                red: Double((value >> 16) & 0xFF) / 255,
                green: Double((value >> 8) & 0xFF) / 255,
                blue: Double(value & 0xFF) / 255,
                opacity: 1
            )
        case 8:
            self.init(
                .sRGB,
                red: Double((value >> 24) & 0xFF) / 255,
                green: Double((value >> 16) & 0xFF) / 255,
                blue: Double((value >> 8) & 0xFF) / 255,
                opacity: Double(value & 0xFF) / 255
            )
        default:
            return nil
        }
    }
}
