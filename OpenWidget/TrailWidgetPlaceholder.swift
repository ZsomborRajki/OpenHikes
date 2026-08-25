//
//  TrailWidgetPlaceholder.swift
//  OpenWidget
//
//  The stand-in trail the widget gallery and the redacted placeholder draw —
//  never a real hike. Kept beside the provider rather than inside it so the
//  timeline logic stays readable next to sixty lines of fixture coordinates.
//

import OpenHikesShared
import SwiftUI

extension TrailWidgetProvider {
    private enum Placeholder {
        static let totalDistanceMeters: Double = 4200
        static let elevationLowMeters: Double = 120
        static let elevationHighMeters: Double = 460
        static let elevationGainMeters: Double = 380
        static let elevationLossMeters: Double = 380
        static let lat0: Double = 37.3349
        static let lon0: Double = -122.0140
        static let lat1: Double = 37.3372
        static let lon1: Double = -122.0098
        static let lat2: Double = 37.3358
        static let lon2: Double = -122.0050
        static let lat3: Double = 37.3400
        static let lon3: Double = -122.0020
        static let lat4: Double = 37.3440
        static let lon4: Double = -122.0060
        /// Part-walked state, for the preview that has to draw every element.
        static let walkedFraction: Double = 0.62
        static let walkedElevationMeters: Double = 335
        static let offRouteMeters: Double = 8
        static let fixAgeSeconds: Double = -90
    }

    /// A generic loop shown in the widget gallery / as a redacted placeholder
    /// — never real trail data. It carries elevations so the gallery shows the
    /// stat chips a real trail would draw rather than an emptier widget than
    /// the one being chosen.
    static let placeholderSnapshot = SharedTrailSnapshot(
        hikeID: UUID(),
        title: "Trail",
        tintHex: "#34C759",
        totalDistanceMeters: Placeholder.totalDistanceMeters,
        polyline: [
            .init(latitude: Placeholder.lat0, longitude: Placeholder.lon0),
            .init(latitude: Placeholder.lat1, longitude: Placeholder.lon1),
            .init(latitude: Placeholder.lat2, longitude: Placeholder.lon2),
            .init(latitude: Placeholder.lat3, longitude: Placeholder.lon3),
            .init(latitude: Placeholder.lat4, longitude: Placeholder.lon4),
        ],
        elevationLowMeters: Placeholder.elevationLowMeters,
        elevationHighMeters: Placeholder.elevationHighMeters,
        elevationGainMeters: Placeholder.elevationGainMeters,
        elevationLossMeters: Placeholder.elevationLossMeters
    )

    /// The same loop, part-walked. Only a preview needs it — the live states
    /// come from the store — but it is the one arrangement where every element
    /// is drawn at once: chips, progress text, and the bar under them.
    static let followedPlaceholderSnapshot: SharedTrailSnapshot = {
        var snapshot = placeholderSnapshot
        snapshot.title = "Ridge Loop"
        snapshot.liveFix = SharedTrailSnapshot.LiveFix(
            coordinate: .init(latitude: Placeholder.lat2, longitude: Placeholder.lon2),
            distanceAlongRouteMeters: Placeholder.totalDistanceMeters * Placeholder.walkedFraction,
            offRouteMeters: Placeholder.offRouteMeters,
            timestamp: .now.addingTimeInterval(Placeholder.fixAgeSeconds),
            elevationMeters: Placeholder.walkedElevationMeters
        )
        return snapshot
    }()
}
