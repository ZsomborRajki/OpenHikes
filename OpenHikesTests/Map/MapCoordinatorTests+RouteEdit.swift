//
//  MapCoordinatorTests+RouteEdit.swift
//  OpenHikesTests
//
//  A new line for the hike already on the map (#1228). *Edit Route* keeps the
//  hike's id, and mirroring can deliver the edit while the hike is selected,
//  so the coordinator has to tell a new line from the same one by the drawn
//  route's revision: the polyline, the points a tap is tested against, the
//  cut at the pauses and the coloured stretches all follow the new line, and
//  the camera does not. `DisplayedRouteCoordinateCacheTests` covers where the
//  revision comes from, and `RouteShadingTests` when the stretches are
//  measured again.
//

import CoreLocation
import Foundation
import MapKit
@testable import OpenHikes
import OpenHikesData
import RealModule
import Testing

// swiftlint:disable no_magic_numbers

extension MapCoordinatorTests {
    /// Six points due east, paused at the fourth when `paused` is set.
    private static func eastward(from latitude: Double, paused: Bool = false) -> [RouteCoordinate] {
        (0..<6).map { index in
            RouteCoordinate(
                latitude: latitude,
                longitude: 12.86 + Double(index) * 0.001,
                boundary: paused && index == 3 ? .paused : nil
            )
        }
    }

    @Test("a new line for the drawn hike replaces its polyline and its tap points")
    func replacedLineIsRedrawn() throws {
        let coordinator = MapView.Coordinator()
        let id = UUID()
        let old = DisplayedRoute(id: id, coordinates: Fixture.coordinates(Self.eastward(from: 47.63)), revision: 1)
        let map = makeMap(mapView(route: old), coordinator)
        defer { detach(map) }
        mapView(route: old).update(map, coordinator)
        let oldLine = try #require(coordinator.routeOverlay)

        let new = DisplayedRoute(id: id, coordinates: Fixture.coordinates(Self.eastward(from: 48.5)), revision: 2)
        mapView(route: new).update(map, coordinator)

        let newLine = try #require(coordinator.routeOverlay)
        #expect(newLine !== oldLine)
        #expect(!map.overlays.contains { $0 === oldLine }, "the old line is no longer drawn")
        #expect(map.overlays.contains { $0 === newLine })
        #expect(newLine.coordinate.latitude.isApproximatelyEqual(to: 48.5, absoluteTolerance: 1e-6))
        #expect(coordinator.routeCoordinates.first?.latitude == 48.5, "a tap is tested against the new line")
    }

    /// The edit can arrive from another device while the hiker is panning,
    /// and a line whose heights were filled in has not moved at all.
    @Test("a new line for the drawn hike leaves the camera where it is")
    func replacedLineIsNotFittedTo() {
        let coordinator = MapView.Coordinator()
        let id = UUID()
        let old = DisplayedRoute(id: id, coordinates: Fixture.coordinates(Self.eastward(from: 47.63)), revision: 1)
        let map = makeMap(mapView(route: old), coordinator)
        defer { detach(map) }
        mapView(route: old).update(map, coordinator)
        let elsewhere = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 40.71, longitude: -74.00),
            latitudinalMeters: 4000,
            longitudinalMeters: 4000
        )
        map.setRegion(elsewhere, animated: false)
        let center = map.region.center

        let new = DisplayedRoute(id: id, coordinates: Fixture.coordinates(Self.eastward(from: 47.64)), revision: 2)
        mapView(route: new).update(map, coordinator)

        #expect(coordinator.routeCoordinates.first?.latitude == 47.64, "precondition: the new line was drawn")
        #expect(map.region.center.latitude == center.latitude)
        #expect(map.region.center.longitude == center.longitude)
    }

    @Test("the same line again is left alone")
    func sameLineIsKept() throws {
        let coordinator = MapView.Coordinator()
        let route = DisplayedRoute(
            id: UUID(),
            coordinates: Fixture.coordinates(Self.eastward(from: 47.63)),
            revision: 1
        )
        let map = makeMap(mapView(route: route), coordinator)
        defer { detach(map) }
        mapView(route: route).update(map, coordinator)
        let line = try #require(coordinator.routeOverlay)

        mapView(route: route).update(map, coordinator)

        #expect(coordinator.routeOverlay === line)
    }

    /// End to end from the stored hike: a pause added to the selected hike's
    /// line, under the same id, cuts the line the map is already drawing.
    @Test("a pause added to the selected hike's line cuts the drawn line")
    func pauseBoundaryEditCutsTheDrawnLine() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, title: "Two Halves", route: Self.eastward(from: 47.63))
        let cache = DisplayedRouteCoordinateCache()
        let coordinator = MapView.Coordinator()
        let before = try #require(DisplayedRoute.forSelection(hike, cache: cache))
        let map = makeMap(mapView(route: before), coordinator)
        defer { detach(map) }
        mapView(route: before).update(map, coordinator)
        #expect(coordinator.routePausedLegs.isEmpty)

        hike.replaceRoute(with: Self.eastward(from: 47.63, paused: true))
        let after = try #require(DisplayedRoute.forSelection(hike, cache: cache))
        mapView(route: after).update(map, coordinator)

        let line = try #require(coordinator.routeOverlay)
        let renderer = try #require(coordinator.mapView(map, rendererFor: line) as? DirectionalPolylineRenderer)
        #expect(renderer.pausedLegs == [2])
        #expect(renderer.runs.map(\.pointCount) == [3, 3])
        #expect(coordinator.pausedRouteOverlays.count == 1, "the paused leg is drawn dotted")
    }

    /// *Color By* is Elevation unless the hiker moved it, and a line with
    /// heights is coloured all along it. The old line's stretches lie where
    /// the old line ran, so the new line is handed none of them, and then
    /// its own.
    @Test("a new line for the drawn hike is coloured by its own stretches, never the old line's")
    func replacedLineIsShadedAgain() async throws {
        let url = try #require(Bundle.main.url(forResource: UITestTrailTagFixture.gpxName, withExtension: "gpx"))
        let route = try GPXImport.load(from: url).route
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, title: "Coloured", route: route)
        let defaults = try #require(UserDefaults(suiteName: "MapCoordinatorTests-elevation-\(UUID().uuidString)"))
        defaults.set(RouteColoring.elevation.rawValue, forKey: SettingsKey.routeColoring)
        let shading = RouteShading(provider: nil, defaults: defaults)
        let cache = DisplayedRouteCoordinateCache()
        let coordinator = MapView.Coordinator()
        let before = try #require(DisplayedRoute.forSelection(hike, cache: cache))
        let map = makeMap(mapView(route: before, base: .system(.standard), routeShading: shading), coordinator)
        defer { detach(map) }
        mapView(route: before, base: .system(.standard), routeShading: shading).update(map, coordinator)
        let oldLine = try #require(coordinator.routeOverlay)
        let oldRenderer = try #require(coordinator.mapView(map, rendererFor: oldLine) as? DirectionalPolylineRenderer)
        shading.follow(hike)
        await shading.measurement?.value
        await settle(until: "the old line's stretches to reach it") { !oldRenderer.shades.isEmpty }

        hike.replaceRoute(with: route.map { point in
            var moved = point
            moved.latitude += 0.5
            return moved
        })
        let after = try #require(DisplayedRoute.forSelection(hike, cache: cache))
        mapView(route: after, base: .system(.standard), routeShading: shading).update(map, coordinator)
        let newLine = try #require(coordinator.routeOverlay)
        let renderer = try #require(coordinator.mapView(map, rendererFor: newLine) as? DirectionalPolylineRenderer)

        #expect(renderer.shades.isEmpty, "the old line's stretches are not drawn on the new one")
        await settle(until: "the new line's own stretches to reach it") { !renderer.shades.isEmpty }
        let bounds = newLine.boundingMapRect.insetBy(dx: -1, dy: -1)
        #expect(renderer.shades.allSatisfy { bounds.contains($0.polyline.boundingMapRect) })
    }
}

// swiftlint:enable no_magic_numbers
