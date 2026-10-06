//
//  MapCoordinatorTests+RouteShading.swift
//  OpenHikesTests
//
//  What the map does with the selected hike's coloured stretches: hands them
//  to the live line, in the Difficulty section's colours, and only to the
//  line they were measured along.
//
//  `RouteShadingTests` covers where the stretches come from; this is
//  the other half of the render-isolated path — the answer landing restyles
//  the renderer MapKit already holds, with no overlay rebuilt and no view
//  re-rendered.
//

import CoreLocation
import Foundation
import MapKit
@testable import OpenHikes
import OpenHikesData
import SwiftData
import SwiftUI
import Testing

extension MapCoordinatorTests {
    private struct GradedFixture {
        let hike: Hike
        let route: [RouteCoordinate]
        let shading: RouteShading
    }

    private func gradedFixture(in context: ModelContext) throws -> GradedFixture {
        let url = try #require(
            Bundle.main.url(forResource: UITestTrailTagFixture.gpxName, withExtension: "gpx")
        )
        let route = try GPXImport.load(from: url).route
        let provider = try #require(BundledTrailGraphProvider(fixtureName: UITestTrailTagFixture.trailGraphName))
        let defaults = try #require(UserDefaults(suiteName: "MapCoordinatorTests-difficulty-\(UUID().uuidString)"))
        defaults.set(RouteColoring.difficulty.rawValue, forKey: SettingsKey.routeColoring)
        return GradedFixture(
            hike: Fixture.hike(in: context, route: route),
            route: route,
            shading: RouteShading(provider: provider, defaults: defaults)
        )
    }

    /// Draws `route` under `id` and asks MapKit's delegate for its renderer,
    /// as MapKit would once the line is on screen.
    private func drawnLine(
        id: UUID,
        route: [RouteCoordinate],
        shading: RouteShading,
        coordinator: MapView.Coordinator
    ) throws -> (map: MKMapView, renderer: DirectionalPolylineRenderer) {
        let view = mapView(
            route: DisplayedRoute(id: id, coordinates: Fixture.coordinates(route)),
            tileSource: nil,
            routeShading: shading
        )
        let map = makeMap(view, coordinator)
        view.update(map, coordinator)
        let line = try #require(coordinator.routeOverlay)
        let renderer = try #require(coordinator.mapView(map, rendererFor: line) as? DirectionalPolylineRenderer)
        return (map, renderer)
    }

    @Test("the selected hike's graded stretches reach the line, in the Difficulty section's colours")
    func gradesReachTheLine() async throws {
        let context = try Fixture.modelContext()
        let fixture = try gradedFixture(in: context)
        let coordinator = MapView.Coordinator()
        let drawn = try drawnLine(
            id: fixture.hike.id,
            route: fixture.route,
            shading: fixture.shading,
            coordinator: coordinator
        )
        defer { detach(drawn.map) }

        fixture.shading.follow(fixture.hike)
        await fixture.shading.measurement?.value
        await settle(until: "the stretches to reach the line") {
            !drawn.renderer.shades.isEmpty
        }

        #expect(drawn.renderer.shades.count == fixture.shading.stretches.count)
        let first = try #require(fixture.shading.stretches.first)
        let shade = try #require(drawn.renderer.shades.first)
        let expected = UIColor(first.shade.color).withAlphaComponent(UIColor(RouteStyle.defaultTint).cgColor.alpha)
        #expect(shade.color == expected.cgColor)
    }

    /// The answer carries the hike it was measured along; a line drawn for
    /// any other hike must not take it, however it arrived.
    @Test("stretches measured along another hike are not drawn on this line")
    func anotherHikesGradesAreNotDrawn() async throws {
        let context = try Fixture.modelContext()
        let fixture = try gradedFixture(in: context)
        let coordinator = MapView.Coordinator()
        let drawn = try drawnLine(id: UUID(), route: fixture.route, shading: fixture.shading, coordinator: coordinator)
        defer { detach(drawn.map) }

        fixture.shading.follow(fixture.hike)
        await fixture.shading.measurement?.value
        await settle(until: "the answer to reach the coordinator") {
            coordinator.shadedHikeID == fixture.hike.id
        }

        #expect(drawn.renderer.shades.isEmpty)
    }

    @Test("None takes the colours off the line")
    func theSwitchClearsTheLine() async throws {
        let context = try Fixture.modelContext()
        let fixture = try gradedFixture(in: context)
        let coordinator = MapView.Coordinator()
        let drawn = try drawnLine(
            id: fixture.hike.id,
            route: fixture.route,
            shading: fixture.shading,
            coordinator: coordinator
        )
        defer { detach(drawn.map) }
        fixture.shading.follow(fixture.hike)
        await fixture.shading.measurement?.value
        await settle(until: "the stretches to reach the line") {
            !drawn.renderer.shades.isEmpty
        }

        fixture.shading.setColoring(.off)
        await settle(until: "the stretches to leave the line") {
            drawn.renderer.shades.isEmpty
        }

        #expect(coordinator.shadedStretches.isEmpty)
    }
}
