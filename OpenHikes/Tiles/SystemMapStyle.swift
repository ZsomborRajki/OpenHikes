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

    /// The least tilt, in degrees, that puts terrain under raster tiles. A
    /// degree rather than zero, so a camera a rounding error off flat is not
    /// taken for one the hiker tilted.
    static let terrainPitch: CLLocationDegrees = 1

    /// Whether raster tiles seen at `pitch` are drawn on terrain. See
    /// `MapCoordinator+TerrainUnderTiles.swift` for why only when tilted.
    static func tilesDrawOnTerrain(atPitch pitch: CLLocationDegrees) -> Bool {
        pitch >= terrainPitch
    }

    /// The configuration under a raster tile overlay. The tiles hide it
    /// either way; what it decides is the ground they are drawn on.
    ///
    /// Off terrain, the flat map: MapKit's default, and what the overlay was
    /// always drawn over. On terrain, the satellite map, whose realistic
    /// elevation the overlay lies over in 3D. Not the standard map's:
    /// realistic draws the Watzmann exactly as flat as `.flat` does.
    ///
    /// Switching from either map above to tiles has to set one of these, or
    /// the tiles would be drawn over whatever the hiker last picked.
    static func underTiles(onTerrain: Bool) -> MKMapConfiguration {
        guard onTerrain else {
            let standard = MKStandardMapConfiguration(elevationStyle: .flat)
            standard.pointOfInterestFilter = .includingAll
            return standard
        }
        return Self.hybrid.configuration
    }
}
