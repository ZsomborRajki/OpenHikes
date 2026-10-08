//
//  MapCoordinatorTests+SystemMapStyle.swift
//  OpenHikesTests
//
//  Which of MapKit's own maps the coordinator configures, and that switching
//  between them and the tile sources happens on the map that is already up.
//
//  The configuration is the whole of what makes *Apple Satellite* a satellite
//  map: it installs no overlay, so without it the entry would draw Apple's
//  street map and nothing would say so.
//

import Foundation
import MapKit
@testable import OpenHikes
import Testing

extension MapCoordinatorTests {
    /// The satellite entry: imagery with its labels, 3D terrain where Apple
    /// has it, every point of interest, and nothing of ours drawn over it.
    @Test("the satellite map is drawn as MapKit's hybrid map, with no overlay")
    func satelliteConfiguresTheHybridMap() throws {
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(base: .system(.hybrid)), coordinator)
        defer { detach(map) }

        let hybrid = try #require(map.preferredConfiguration as? MKHybridMapConfiguration)
        #expect(hybrid.elevationStyle == .realistic)
        #expect(hybrid.pointOfInterestFilter == .includingAll)
        #expect(coordinator.tileOverlay == nil)
        #expect(map.overlays.isEmpty)
        #if os(iOS)
        #expect(map.overrideUserInterfaceStyle == .unspecified, "the chrome follows the phone over imagery")
        #expect(try #require(coordinator.attributionView).isHidden, "MapKit draws its own credit")
        #endif
    }

    /// Apple Maps keeps its own map, now with the same 3D terrain.
    @Test("Apple Maps is drawn as MapKit's standard map with realistic elevation")
    func appleMapsConfiguresTheStandardMap() throws {
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(base: .system(.standard)), coordinator)
        defer { detach(map) }

        let standard = try #require(map.preferredConfiguration as? MKStandardMapConfiguration)
        #expect(standard.elevationStyle == .realistic)
        #expect(standard.pointOfInterestFilter == .includingAll)
    }

    /// Under tiles the map is what it always was: flat, so the overlay is
    /// drawn as it always has been.
    @Test("a tile source is drawn over a flat standard map")
    func tilesKeepAFlatMapUnderneath() throws {
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(), coordinator)
        defer { detach(map) }

        let standard = try #require(map.preferredConfiguration as? MKStandardMapConfiguration)
        #expect(standard.elevationStyle == .flat)
        #expect(standard.pointOfInterestFilter == .includingAll)
        #expect(coordinator.tileOverlay != nil)
    }

    /// The choice is made in Settings while the map is up, and taken back the
    /// same way: every step has to land on the map that is already there,
    /// with the route on it untouched, rather than on a rebuilt one.
    @Test("switching to satellite and back reconfigures the same map")
    func switchingStylesIsLive() throws {
        let coordinator = MapView.Coordinator()
        let route = Self.route()
        let view = mapView(route: route)
        let map = makeMap(view, coordinator)
        defer { detach(map) }
        view.update(map, coordinator)
        let line = try #require(coordinator.routeOverlay)

        mapView(route: route, base: .system(.hybrid)).update(map, coordinator)
        #expect(map.preferredConfiguration is MKHybridMapConfiguration)
        #expect(coordinator.tileOverlay == nil)

        mapView(route: route, base: .system(.standard)).update(map, coordinator)
        let standard = try #require(map.preferredConfiguration as? MKStandardMapConfiguration)
        #expect(standard.elevationStyle == .realistic)

        mapView(route: route, base: .system(.hybrid)).update(map, coordinator)
        #expect(map.preferredConfiguration is MKHybridMapConfiguration)

        mapView(route: route).update(map, coordinator)
        let flat = try #require(map.preferredConfiguration as? MKStandardMapConfiguration)
        #expect(flat.elevationStyle == .flat)
        #expect(coordinator.tileOverlay != nil)
        #expect(coordinator.routeOverlay === line, "the route must survive every switch")
        #expect(map.overlays.first === coordinator.tileOverlay, "tiles must stay under the route line")
    }

    /// An update that changes nothing must not hand MapKit a new
    /// configuration: it would redraw the whole map, and `update` runs on
    /// every SwiftUI pass that reaches it.
    @Test("an update that changes nothing keeps the same configuration")
    func repeatedUpdatesKeepTheConfiguration() {
        let coordinator = MapView.Coordinator()
        let view = mapView(base: .system(.hybrid))
        let map = makeMap(view, coordinator)
        defer { detach(map) }
        let installed = map.preferredConfiguration

        view.update(map, coordinator)
        view.update(map, coordinator)

        #expect(map.preferredConfiguration === installed)
    }
}
