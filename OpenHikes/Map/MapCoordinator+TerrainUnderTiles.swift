//
//  MapCoordinator+TerrainUnderTiles.swift
//  OpenHikes
//
//  The ground the raster tiles are drawn on: the flat map while the map lies
//  flat, the satellite map's terrain once the hiker tilts it.
//
//  MapKit drapes a replacing `MKTileOverlay` over the realistic elevation of
//  the map it replaces, as it drapes every line. So OpenStreetMap, Stadia
//  and Thunderforest lie over the mountains in 3D on a terrain whose imagery
//  they hide. Watched on iOS 18.6 and 27.2 simulators,
//  never on a device, and against WWDC22's word for iOS 16 that an overlay
//  flattens a realistic map. Only the satellite map lends terrain:
//  ``SystemMapStyle/underTiles(onTerrain:)`` says why not the standard one.
//
//  Only while tilted, because terrain is neither free nor much to look at
//  from straight above:
//
//  - MapKit keeps fetching a replaced map's own tiles. Under the flat map
//    those are its street map's; under the satellite map, the imagery the
//    tiles then cover. Counted in MapKit's tile cache over a mountain it had
//    not loaded, seen from 3.5 km at 35°: 24 tiles and 298 KB under the flat
//    map, 29 tiles and 833 KB under the satellite map.
//  - `convert(_:toPointTo:)` projects onto a flat map, while on terrain
//    MapKit draws the lines and places the pins on the ground, and
//    ``RouteHitTest`` measures every line tap through `convert`. Seen from
//    3.5 km straight down, a point a kilometre along the Watzmann's ridge
//    sat 50 pt from where `convert` put it; tilted to 35°, one 800 m down
//    the east face was 170 pt out. A hiker who tilted the map is looking at
//    the relief, not aiming at a line.
//
//  Switched where the map settles, as everything here that follows the
//  camera is, so a gesture is never cut into by a new configuration. MapKit
//  keeps the camera across one, centre, distance and pitch alike on both
//  runtimes, so the terrain rises under the tiles where they already are.
//

import MapKit

extension MapView.Coordinator {
    /// Puts the map under the tiles that the camera's tilt asks for.
    ///
    /// A comparison on every settle but the one that crosses
    /// ``SystemMapStyle/terrainPitch``, so a pan never hands MapKit a
    /// configuration, which would redraw the whole map. Nothing over Apple's
    /// own maps, whose configuration is the style's.
    func applyTerrainUnderTiles(on mapView: MKMapView) {
        guard tileOverlay != nil else { return }
        let onTerrain = SystemMapStyle.tilesDrawOnTerrain(atPitch: mapView.camera.pitch)
        guard onTerrain != tilesOnTerrain else { return }
        tilesOnTerrain = onTerrain
        mapView.preferredConfiguration = SystemMapStyle.underTiles(onTerrain: onTerrain)
    }
}
