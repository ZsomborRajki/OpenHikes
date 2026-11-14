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
    static let routesLayer = TileLayer.hikingRoutes

    /// Squares from a stub and kept nowhere: a map under test may ask for
    /// them as it lays out, and must reach neither the public database nor
    /// the app's `Caches`.
    static let routeSquares = HikingRouteSquares(database: StubTrailCellDatabase(), directory: nil)

    /// The map with the layer switched on, drawn from the stub's squares.
    func layeredMapView(route: DisplayedRoute? = nil, base: MapBase = .tiles(osm)) -> MapView {
        mapView(route: route, base: base, tileLayer: Self.routesLayer, hikingRouteSquares: Self.routeSquares)
    }

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
        let map = makeMap(layeredMapView(), coordinator)
        defer { detach(map) }

        let base = try #require(coordinator.tileOverlay)
        let layer = try #require(coordinator.layerOverlay)
        #expect(stack(map).map(ObjectIdentifier.init) == [ObjectIdentifier(base), ObjectIdentifier(layer)])
        #expect(layer.squares === Self.routeSquares, "the layer draws from the squares it was handed")
        #expect(coordinator.mapView(map, rendererFor: layer) is HikingRoutesRenderer)
    }

    /// A hosted suite and a UI-testing launch have no squares, and a layer
    /// built without them would have nothing to draw from.
    @Test("with no squares the switch puts no layer on, and the line still credits it")
    func noSquaresNoLayer() throws {
        #if os(iOS)
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(base: .system(.standard), tileLayer: Self.routesLayer), coordinator)
        defer { detach(map) }

        #expect(coordinator.layerOverlay == nil)
        #expect(stack(map).isEmpty)
        let credit = try #require(coordinator.attributionView)
        #expect(!credit.isHidden)
        #endif
    }

    /// The case the layer is most wanted for: satellite or Apple's own map
    /// underneath, which has no tile overlay of ours to sit on.
    @Test(
        "over Apple's maps the layer is the only overlay, and the map stays drawn",
        arguments: [SystemMapStyle.standard, .hybrid]
    )
    func layerDrawsOverTheSystemBaseMap(style: SystemMapStyle) throws {
        let coordinator = MapView.Coordinator()
        let map = makeMap(layeredMapView(base: .system(style)), coordinator)
        defer { detach(map) }

        let layer = try #require(coordinator.layerOverlay)
        #expect(coordinator.tileOverlay == nil)
        #expect(stack(map).count == 1)
        #expect(stack(map).first === layer)
    }

    @Test("an update that changes nothing keeps the same layer")
    func repeatedUpdatesReuseTheLayer() throws {
        let coordinator = MapView.Coordinator()
        let view = layeredMapView()
        let map = makeMap(view, coordinator)
        defer { detach(map) }
        let installed = try #require(coordinator.layerOverlay)

        view.update(map, coordinator)
        view.update(map, coordinator)

        #expect(coordinator.layerOverlay === installed)
        #expect(stack(map).count == 2)
    }

    @Test("switching the layer off takes it off and leaves the map's tiles")
    func switchingOffRemovesTheLayer() throws {
        let coordinator = MapView.Coordinator()
        let map = makeMap(layeredMapView(), coordinator)
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

        layeredMapView(route: route).update(map, coordinator)

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
        let map = makeMap(layeredMapView(base: .system(.standard)), coordinator)
        defer { detach(map) }

        layeredMapView(route: Self.route(), base: .system(.standard)).update(map, coordinator)

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
        let map = makeMap(layeredMapView(base: .system(.standard)), coordinator)
        defer { detach(map) }
        let layer = try #require(coordinator.layerOverlay)

        layeredMapView().update(map, coordinator)

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

        layeredMapView(base: .system(.standard)).update(map, coordinator)
        #expect(!credit.isHidden)
        #expect(spokenCredit(credit)?.contains("OpenStreetMap") == true)

        mapView(base: .system(.standard)).update(map, coordinator)
        #expect(credit.isHidden, "and takes it away again")
        #endif
    }

    @Test("over a raster map the line credits the map and then the layer")
    func layerIsCreditedAfterTheMap() throws {
        #if os(iOS)
        let coordinator = MapView.Coordinator()
        let map = makeMap(layeredMapView(), coordinator)
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
