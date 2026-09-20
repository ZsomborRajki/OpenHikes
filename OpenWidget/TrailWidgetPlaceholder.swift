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
    /// The stand-in route, above the Königssee in Berchtesgaden — the same
    /// valley `Scripts/screenshots.sh` stages the App Store frames in, so a
    /// hiker meets one place across the gallery, the store listing and the
    /// widget they end up placing.
    ///
    /// **It has to be somewhere that looks like a hike**, because the gallery
    /// draws a real basemap under it now: this route used to run through a
    /// Cupertino street grid, and four rendered images of a suburb is a
    /// hiking widget advertising itself with a map of parked cars. Forest,
    /// streams and a lake edge are what the widget is for.
    ///
    /// The figures are the ones the real route would carry — a 2.6 km climb
    /// out of the lake basin — rather than round numbers, so the chips in the
    /// gallery are the chips a real trail draws. Moving any of these means
    /// re-running `Scripts/placeholder-basemaps.sh`; the test named in its
    /// header is what says so.
    private enum Placeholder {
        static let totalDistanceMeters: Double = 2614
        static let elevationLowMeters: Double = 603
        static let elevationHighMeters: Double = 985
        static let elevationGainMeters: Double = 420
        static let elevationLossMeters: Double = 38
        static let lat0: Double = 47.5860
        static let lon0: Double = 12.9880
        static let lat1: Double = 47.5895
        static let lon1: Double = 12.9955
        static let lat2: Double = 47.5925
        static let lon2: Double = 13.0035
        static let lat3: Double = 47.5958
        static let lon3: Double = 13.0112
        static let lat4: Double = 47.5985
        static let lon4: Double = 13.0175
        /// Part-walked state, for the preview that has to draw every element.
        static let walkedFraction: Double = 0.62
        static let walkedElevationMeters: Double = 812
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
        tintHex: "#1B7F3B",
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
        snapshot.title = "Jenner Ridge"
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
