//
//  SystemMapStyle.swift
//  OpenHikes
//
//  Which of MapKit's own maps a catalog entry draws, and the configuration
//  the map view and the Settings card are given for it.
//

import MapKit

/// One of MapKit's own maps, drawn in place of raster tiles. See
/// ``TileProvider/systemStyle``.
///
/// `nonisolated` because the catalog it is stored in is: the tile-loading
/// code reads ``TileProvider`` off the main actor.
nonisolated enum SystemMapStyle: String, Hashable, Sendable {
    /// Apple's satellite imagery with its labels drawn over it, the *Apple
    /// Satellite* entry.
    case hybrid = "hybrid"
    /// Apple's vector cartography, the *Apple Maps* entry.
    case standard = "standard"
}

extension SystemMapStyle {
    /// The configuration to draw this map with.
    ///
    /// Realistic elevation for both, so terrain is 3D where Apple has it once
    /// the map is pitched — the relief is the half of a hiking map MapKit's
    /// own maps do have. Every point of interest, as the map has always
    /// shown: a new configuration replaces the map's filter rather than
    /// keeping it, so it is set here and not on the view.
    var configuration: MKMapConfiguration {
        switch self {
        case .standard:
            let standard = MKStandardMapConfiguration(elevationStyle: .realistic)
            standard.pointOfInterestFilter = .includingAll
            return standard
        case .hybrid:
            let hybrid = MKHybridMapConfiguration(elevationStyle: .realistic)
            hybrid.pointOfInterestFilter = .includingAll
            return hybrid
        }
    }

    /// The configuration under a raster tile overlay: flat, which is MapKit's
    /// default and what the overlay was always drawn over. Switching from
    /// either map above to tiles has to put it back, or the tiles would be
    /// drawn over whatever the hiker last picked.
    static var underTiles: MKMapConfiguration {
        let standard = MKStandardMapConfiguration(elevationStyle: .flat)
        standard.pointOfInterestFilter = .includingAll
        return standard
    }
}
