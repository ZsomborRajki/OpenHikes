//
//  MapCoordinatorTests+TerrainUnderTiles.swift
//  OpenHikesTests
//
//  The ground under the raster tiles: the flat map while the map lies flat,
//  the satellite map's terrain once it is tilted. Switched where the map
//  settles, only when the tilt crosses the line, and never over Apple's own
//  maps, whose configuration is their style's.
//
//  What is asserted is the configuration handed to MapKit. That MapKit then
//  drapes the tiles over the terrain is its own doing, watched on two
//  simulators and argued in `MapCoordinator+TerrainUnderTiles.swift`; a map
//  that is never in a window renders nothing a test could look at.
//

import CoreLocation
import Foundation
import MapKit
@testable import OpenHikes
import RealModule
import Testing

extension MapCoordinatorTests {
    /// Close enough for MapKit to allow a tilt: it allows none from orbit.
    private static let tiltableDistance: CLLocationDistance = 3500

    /// Tilts `map` where it already looks and tells the coordinator it
    /// settled there, as a gesture's end does.
    private func settleTilt(_ map: MKMapView, _ coordinator: MapView.Coordinator, at pitch: CLLocationDegrees) throws {
        map.camera = MKMapCamera(
            lookingAtCenter: map.centerCoordinate,
            fromDistance: Self.tiltableDistance,
            pitch: pitch,
            heading: 0
        )
        try #require(
            map.camera.pitch.isApproximatelyEqual(to: pitch, absoluteTolerance: 1),
            "MapKit must take the tilt, or nothing below tests anything"
        )
        coordinator.mapView(map, regionDidChangeAnimated: false)
    }

    @Test("tilting the map puts the satellite terrain under the tiles, and laying it flat takes it away")
    func tiltingSwitchesTheTerrainUnderTheTiles() throws {
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(), coordinator)
        defer { detach(map) }

        try settleTilt(map, coordinator, at: 30)
        let terrain = try #require(map.preferredConfiguration as? MKHybridMapConfiguration)
        #expect(terrain.elevationStyle == .realistic)
        #expect(terrain.pointOfInterestFilter == .includingAll)
        let tiles = try #require(coordinator.tileOverlay)
        #expect(tiles.canReplaceMapContent, "the tiles still cover the imagery")
        #expect(map.overlays.first === tiles, "the same tiles, still under every line")

        try settleTilt(map, coordinator, at: 0)
        let flat = try #require(map.preferredConfiguration as? MKStandardMapConfiguration)
        #expect(flat.elevationStyle == .flat)
        #expect(coordinator.tileOverlay === tiles)
    }

    /// Every settle passes through here, a pan as much as a tilt, and a new
    /// configuration redraws the whole map.
    @Test("a settle that stays on the same side of the line keeps the configuration")
    func settlesOnTheSameSideKeepTheConfiguration() throws {
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(), coordinator)
        defer { detach(map) }

        let flat = map.preferredConfiguration
        try settleTilt(map, coordinator, at: 0)
        #expect(map.preferredConfiguration === flat)

        try settleTilt(map, coordinator, at: 30)
        let terrain = map.preferredConfiguration
        try settleTilt(map, coordinator, at: 20)
        #expect(map.preferredConfiguration === terrain)
    }

    @Test("a tilt leaves Apple's own maps as their style draws them", arguments: [SystemMapStyle.standard, .hybrid])
    func tiltLeavesTheSystemMapsAlone(style: SystemMapStyle) throws {
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(base: .system(style)), coordinator)
        defer { detach(map) }
        let installed = map.preferredConfiguration

        try settleTilt(map, coordinator, at: 30)
        try settleTilt(map, coordinator, at: 0)

        #expect(map.preferredConfiguration === installed)
    }

    /// A style picked in Settings while the map behind the sheet is tilted:
    /// no settle comes to switch it, so the switch to tiles has to.
    @Test("tiles picked while the map is tilted go straight onto the terrain")
    func tilesPickedWhileTiltedStartOnTheTerrain() throws {
        let coordinator = MapView.Coordinator()
        let route = Self.route()
        let view = mapView(route: route, base: .system(.standard))
        let map = makeMap(view, coordinator)
        defer { detach(map) }
        // The first update draws the route and fits the camera to it, which
        // lays the map flat; a map the hiker tilted has long been through it.
        view.update(map, coordinator)
        try settleTilt(map, coordinator, at: 30)

        mapView(route: route).update(map, coordinator)
        let terrain = try #require(map.preferredConfiguration as? MKHybridMapConfiguration)
        #expect(terrain.elevationStyle == .realistic)
        #expect(coordinator.tileOverlay != nil)

        try settleTilt(map, coordinator, at: 0)
        let flat = try #require(map.preferredConfiguration as? MKStandardMapConfiguration)
        #expect(flat.elevationStyle == .flat, "laying it flat must take that terrain away too")
    }

    @Test(
        "terrain starts at a degree of tilt",
        arguments: [(0.0, false), (0.5, false), (1.0, true), (35.0, true)]
    )
    func terrainStartsAtADegreeOfTilt(pitch: CLLocationDegrees, onTerrain: Bool) {
        #expect(SystemMapStyle.tilesDrawOnTerrain(atPitch: pitch) == onTerrain)
    }
}
