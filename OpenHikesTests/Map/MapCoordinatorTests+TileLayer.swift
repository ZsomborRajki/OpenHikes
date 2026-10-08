//
//  MapCoordinatorTests+TileLayer.swift
//  OpenHikesTests
//
//  The hiking-route layer's place in the map's one overlay level: over the
//  selected map's tiles — or over Apple's map, with nothing replaced — and
//  under every line. Each claim is checked on the `MKMapView` itself, in the
//  order MapKit will draw, rather than on the code that was meant to put it
//  there.
//

import Foundation
import MapKit
@testable import OpenHikes
import Testing

extension MapCoordinatorTests {
    /// The real layer's credits and zoom range, behind a host that cannot
    /// resolve: nothing here draws, but nothing here should be able to ask a
    /// volunteer's server for a tile either.
    static let routesLayer = TileLayer(
        id: "layer_test",
        urlTemplate: "https://layer.example.invalid/{z}/{x}/{y}.png",
        minimumZ: TileLayer.waymarkedHiking.minimumZ,
        maximumZ: TileLayer.waymarkedHiking.maximumZ,
        attribution: TileLayer.waymarkedHiking.attribution
    )

    #if os(iOS)
    /// What VoiceOver reads for the line: the canonical credits, carried by
    /// the one button inside it.
    private func spokenCredit(_ credit: MapAttributionView) -> String? {
        credit.subviews.lazy.compactMap { $0 as? UIButton }.first?.accessibilityLabel
    }
    #endif

    /// The level's overlays, bottom first — the order they are drawn in.
    private func stack(_ map: MKMapView) -> [any MKOverlay] {
        map.overlays(in: .aboveLabels)
    }

    @Test("the layer goes on directly above the map's tiles, without replacing them")
    func layerSitsAboveTheBaseTiles() throws {
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(tileLayer: Self.routesLayer), coordinator)
        defer { detach(map) }

        let base = try #require(coordinator.tileOverlay)
        let layer = try #require(coordinator.layerOverlay)
        #expect(stack(map).map(ObjectIdentifier.init) == [ObjectIdentifier(base), ObjectIdentifier(layer)])
        #expect(!layer.canReplaceMapContent, "a layer that replaced the map would blank whatever is under it")
        #expect(layer.providerID == Self.routesLayer.id, "its tiles are filed under its own namespace")
        #expect(layer.minimumZ == Self.routesLayer.minimumZ)
        #expect(layer.maximumZ == Self.routesLayer.maximumZ)
    }

    /// The case the layer is most wanted for: satellite or Apple's own map
    /// underneath, which has no tile overlay of ours to sit on.
    @Test(
        "over Apple's maps the layer is the only overlay, and the map stays drawn",
        arguments: [SystemMapStyle.standard, .hybrid]
    )
    func layerDrawsOverTheSystemBaseMap(style: SystemMapStyle) throws {
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(base: .system(style), tileLayer: Self.routesLayer), coordinator)
        defer { detach(map) }

        let layer = try #require(coordinator.layerOverlay)
        #expect(coordinator.tileOverlay == nil)
        #expect(stack(map).count == 1)
        #expect(stack(map).first === layer)
        #expect(!layer.canReplaceMapContent)
    }

    @Test("an update that changes nothing keeps the same layer")
    func repeatedUpdatesReuseTheLayer() throws {
        let coordinator = MapView.Coordinator()
        let view = mapView(tileLayer: Self.routesLayer)
        let map = makeMap(view, coordinator)
        defer { detach(map) }
        let installed = try #require(coordinator.layerOverlay)

        view.update(map, coordinator)
        view.update(map, coordinator)

        #expect(coordinator.layerOverlay === installed)
        #expect(stack(map).count(where: { $0 is TileOverlay }) == 2)
    }

    @Test("switching the layer off takes it off and leaves the map's tiles")
    func switchingOffRemovesTheLayer() throws {
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(tileLayer: Self.routesLayer), coordinator)
        defer { detach(map) }
        let base = try #require(coordinator.tileOverlay)

        mapView().update(map, coordinator)

        #expect(coordinator.layerOverlay == nil)
        #expect(stack(map).count == 1)
        #expect(stack(map).first === base)
    }

    /// Switched on with a hike already drawn — the usual order, since the
    /// switch is in Settings and a hike is open behind it. The layer has to
    /// slide in under the line rather than be stacked on top of it.
    @Test("switching the layer on under a drawn route keeps the route on top")
    func layerGoesUnderAnExistingRoute() throws {
        let coordinator = MapView.Coordinator()
        let route = Self.route()
        let map = makeMap(mapView(route: route), coordinator)
        defer { detach(map) }
        mapView(route: route).update(map, coordinator)
        let line = try #require(coordinator.routeOverlay)

        mapView(route: route, tileLayer: Self.routesLayer).update(map, coordinator)

        let layer = try #require(coordinator.layerOverlay)
        let order = stack(map)
        let layerIndex = try #require(order.firstIndex { $0 === layer })
        let lineIndex = try #require(order.firstIndex { $0 === line })
        #expect(layerIndex == 1, "directly above the map's tiles")
        #expect(layerIndex < lineIndex, "the layer is drawn over the hiker's own line")
    }

    /// And a route drawn after the layer is already on anchors above the
    /// layer rather than on the map's tiles beneath it.
    @Test("a route drawn over the layer goes above it")
    func routeGoesAboveAnExistingLayer() throws {
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(base: .system(.standard), tileLayer: Self.routesLayer), coordinator)
        defer { detach(map) }

        mapView(route: Self.route(), base: .system(.standard), tileLayer: Self.routesLayer).update(map, coordinator)

        let line = try #require(coordinator.routeOverlay)
        #expect(stack(map).first === coordinator.layerOverlay)
        #expect(stack(map).contains { $0 === line })
        #expect(stack(map).first !== line)
    }

    /// Changing map with the layer on re-inserts the map's tiles `at: 0`,
    /// which is what keeps them underneath without the layer being touched.
    @Test("changing map with the layer on keeps the layer above the new tiles")
    func changingMapKeepsTheLayerOnTop() throws {
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(base: .system(.standard), tileLayer: Self.routesLayer), coordinator)
        defer { detach(map) }
        let layer = try #require(coordinator.layerOverlay)

        mapView(tileLayer: Self.routesLayer).update(map, coordinator)

        let base = try #require(coordinator.tileOverlay)
        #expect(coordinator.layerOverlay === layer, "the layer did not need rebuilding")
        #expect(stack(map).map(ObjectIdentifier.init) == [ObjectIdentifier(base), ObjectIdentifier(layer)])
    }

    /// Apple's map hides the credit line, because MapKit credits itself. A
    /// layer over it is owed a credit all the same.
    @Test("the layer brings the credit line back over Apple's map")
    func layerIsCreditedOverTheSystemBaseMap() throws {
        #if os(iOS)
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(base: .system(.standard)), coordinator)
        defer { detach(map) }
        let credit = try #require(coordinator.attributionView)
        #expect(credit.isHidden, "precondition: nothing of ours to credit")

        mapView(base: .system(.standard), tileLayer: Self.routesLayer).update(map, coordinator)
        #expect(!credit.isHidden)
        #expect(spokenCredit(credit)?.contains("Waymarked Trails") == true)

        mapView(base: .system(.standard)).update(map, coordinator)
        #expect(credit.isHidden, "and takes it away again")
        #endif
    }

    @Test("over a raster map the line credits the map and then the layer")
    func layerIsCreditedAfterTheMap() throws {
        #if os(iOS)
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(tileLayer: Self.routesLayer), coordinator)
        defer { detach(map) }
        let credit = try #require(coordinator.attributionView)

        let expected = TileAttribution.drawn(
            base: Self.osm.attribution,
            layer: Self.routesLayer.attribution
        )
        #expect(spokenCredit(credit) == expected?.plainText)
        #endif
    }
}
