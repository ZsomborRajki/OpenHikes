//
//  MapCoordinatorTests+TrailDraftShading.swift
//  OpenHikesTests
//
//  The trail being drawn, coloured on a real `MKMapView` — see
//  `MapTrailDraftShading.swift`. The heights are handed to the shading
//  directly, because the maker these suites share has no elevation source and
//  none may reach a network; what is measured from them is
//  `TrailDraftShadingTests`'.
//

import CoreLocation
import Foundation
import MapKit
import Observation
@testable import OpenHikes
import OpenHikesData
import Testing

extension MapCoordinatorTests {
    private enum Slope {
        static let longitude: Double = -122.0300
        static let south: Double = 37.3300
        static let north: Double = 37.3400
        static let low: Double = 100
        static let high: Double = 200
    }

    /// Whether OpenHikes Pro is on, observable as the entitlement store is.
    /// Not private: the `@Observable` expansion cannot see a private type.
    @Observable
    final class Unlock {
        var isOn = false
    }

    /// A two-stop hiking trail with its heights in, on a map, coloured by
    /// `shading`'s control. `maker` defaults to the suite's own.
    private func colouredTrail(
        _ coordinator: MapView.Coordinator,
        shading: RouteShading,
        maker: TrailDraftController? = nil
    ) async -> MKMapView {
        let drawing = maker ?? trailMaker
        let map = makeMap(mapView(trailMaker: drawing, routeShading: shading), coordinator)
        drawing.setEditing(true)
        drawing.appendWaypoint(at: CLLocationCoordinate2D(latitude: Slope.south, longitude: Slope.longitude))
        drawing.appendWaypoint(at: CLLocationCoordinate2D(latitude: Slope.north, longitude: Slope.longitude))
        let route = drawing.draft.routeCoordinates
        drawing.shading.heightsDidLand(
            RouteHeightSamples(
                routePointCount: route.count,
                indexes: Array(route.indices),
                coordinates: route,
                heights: [Slope.low, Slope.high]
            )
        )
        await drawing.shading.measurement?.value
        return map
    }

    private func scratchShading(_ coloring: RouteColoring) throws -> RouteShading {
        let defaults = try #require(UserDefaults(suiteName: "TrailDraftShading-\(UUID().uuidString)"))
        defaults.set(coloring.rawValue, forKey: SettingsKey.routeColoring)
        return RouteShading(provider: nil, defaults: defaults)
    }

    @Test("the drawn line is coloured in the way every hike is, above its legs")
    func drawnLineIsColoured() async throws {
        #if os(iOS)
        let coordinator = MapView.Coordinator()
        let map = await colouredTrail(coordinator, shading: try scratchShading(.elevation))
        defer { detach(map) }

        await settle(until: "the colours to reach the map") { coordinator.trailDraftShades.line != nil }
        let line = try #require(coordinator.trailDraftShades.line)
        let renderer = try #require(coordinator.mapView(map, rendererFor: line) as? DirectionalPolylineRenderer)
        #expect(renderer.shades.count == 1)
        #expect(renderer.strokeColor?.cgColor.alpha == 0, "only the stretches are drawn; the leg shows elsewhere")
        let legs = coordinator.trailDraftOverlays.map { ObjectIdentifier($0) }
        let shadeIndex = try #require(map.overlays.firstIndex { $0 === line })
        let topLeg = try #require(map.overlays.lastIndex { overlay in legs.contains(ObjectIdentifier(overlay)) })
        #expect(shadeIndex > topLeg)
        #endif
    }

    /// The control is shared: *None* picked on any hike's Route Style takes
    /// the colours off the trail being drawn, and moving it back brings them.
    @Test("None on the shared control takes the colours off the drawn line")
    func noneTakesTheColoursOff() async throws {
        #if os(iOS)
        let coordinator = MapView.Coordinator()
        let shading = try scratchShading(.elevation)
        let map = await colouredTrail(coordinator, shading: shading)
        defer { detach(map) }
        await settle(until: "the colours to reach the map") { coordinator.trailDraftShades.line != nil }
        let coloured = try #require(coordinator.trailDraftShades.line)

        shading.setColoring(.off)
        await settle(until: "None to take them off") { coordinator.trailDraftShades.line == nil }
        #expect(!map.overlays.contains { $0 === coloured })

        shading.setColoring(.elevation)
        await settle(until: "Elevation to bring them back") { coordinator.trailDraftShades.line != nil }
        #endif
    }

    /// The colours are about the line as it was, and a moved line has not
    /// been measured yet.
    @Test("a moved line takes its colours off until it is measured again")
    func movingTheLineTakesThemOff() async throws {
        #if os(iOS)
        let coordinator = MapView.Coordinator()
        let map = await colouredTrail(coordinator, shading: try scratchShading(.elevation))
        defer { detach(map) }
        await settle(until: "the colours to reach the map") { coordinator.trailDraftShades.line != nil }

        trailMaker.appendWaypoint(at: CLLocationCoordinate2D(latitude: Slope.north + 0.01, longitude: Slope.longitude))

        await settle(until: "the edit to take them off") { coordinator.trailDraftShades.line == nil }
        #endif
    }

    /// Without OpenHikes Pro the maker's *Elevation* draws by difficulty —
    /// none here, since this maker has no graph — so heights alone colour
    /// nothing, and a purchase brings the steepness in without the line
    /// being touched.
    @Test("without Pro, Elevation draws no steepness until the subscription arrives")
    func elevationWaitsForPro() async throws {
        #if os(iOS)
        let unlock = Unlock()
        let maker = TrailDraftController(elevationUnlocked: { unlock.isOn })
        let coordinator = MapView.Coordinator()
        // Held here: the map holds the control weakly.
        let shading = try scratchShading(.elevation)
        let map = await colouredTrail(coordinator, shading: shading, maker: maker)
        defer { detach(map) }

        #expect(!maker.shading.stretches(for: .elevation).isEmpty, "precondition: the steepness is measured")
        coordinator.refreshTrailDraftShades(on: map)
        #expect(coordinator.trailDraftShades.coloring === shading)
        #expect(coordinator.trailDraftShades.line == nil)

        unlock.isOn = true
        await settle(until: "the purchase to bring the colours") { coordinator.trailDraftShades.line != nil }
        #endif
    }
}
