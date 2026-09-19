//
//  WatchMapStyle.swift
//  OpenHikesWatch
//
//  What the basemap under a trail is made of, and what it bothers to name.
//
//  ## Why this exists at all
//
//  Apple's vector map is thin where hiking happens. It has the roads and the
//  big paths and then, above the treeline, very little — which on a wrist is
//  the difference between a map and a green background with one line on it.
//  Nothing can be done about that with tiles of our own: `MKTileOverlay`,
//  `MKTileOverlayRenderer` and `MKMapView` are all `API_UNAVAILABLE(watchos)`,
//  so OpenTopoMap and the rest cannot be drawn on a watch at any price.
//
//  What *is* available is three settings on Apple's own map, and together they
//  are most of the difference:
//
//  - **Satellite.** Where the vector map has nothing, the imagery still shows
//    the ground — the scree, the treeline, the cut of the path across it.
//    Often the trail is visible in the picture when no line is drawn for it.
//  - **Realistic elevation**, which shades the relief. A valley reads as a
//    valley, so a trail that contours around a spur looks like what it is
//    rather than like a wiggle.
//  - **Fewer points of interest.** The default draws everything a city has.
//    Filtering to what a hiker would walk to — water, shelter, a car park, a
//    bus stop — leaves room on a 44 mm screen for the trail.
//

import MapKit
import SwiftUI

/// The basemap a hiker picked, remembered between walks.
enum WatchMapStyle: String, CaseIterable, Identifiable {
    case satellite = "satellite"
    case standard = "standard"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: "Map"
        case .satellite: "Satellite"
        }
    }

    /// What a hiker might actually walk to, and nothing else.
    ///
    /// Water and a lavatory are the two a long day turns on; a car park and a
    /// bus stop are how the walk starts and ends; the rest are shelter and the
    /// numbers worth having when something has gone wrong.
    private static let hikingPointsOfInterest: [MKPointOfInterestCategory] = [
        .nationalPark, .park, .campground, .beach, .marina,
        .restroom, .parking, .publicTransport,
        .cafe, .restaurant, .hotel,
        .hospital, .fireStation, .police,
    ]

    var mapStyle: MapStyle {
        switch self {
        case .standard:
            // Realistic rather than flat: the relief is the half of a hiking
            // map Apple's vector layer does have, and it costs nothing to ask
            // for. Muted emphasis puts the roads behind the route drawn on
            // top of them, which is the one line on this screen that matters.
            .standard(
                elevation: .realistic,
                emphasis: .muted,
                pointsOfInterest: .including(Self.hikingPointsOfInterest)
            )
        case .satellite:
            // Hybrid rather than plain imagery, because a picture with no
            // names in it cannot be checked against a signpost.
            .hybrid(
                elevation: .realistic,
                pointsOfInterest: .including(Self.hikingPointsOfInterest)
            )
        }
    }
}
