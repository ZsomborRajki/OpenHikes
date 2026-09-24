//
//  MapCoordinatorTests+TrailDraftTint.swift
//  OpenHikesTests
//
//  The trail being drawn takes its colour from the map, not the app — see
//  `MapTrailDraftTint.swift`.
//
//  The map's appearance is set by hand rather than by handing it a tile
//  source, because `overrideUserInterfaceStyle` is the whole of what a tile
//  source changes here, and the test process's own appearance is whatever the
//  simulator is in. Each assertion names both variants, so a line resolved
//  against the app instead of the map fails under one of them whichever that
//  is.
//

import CoreLocation
import Foundation
import MapKit
@testable import OpenHikes
import SwiftUI
import Testing
#if canImport(UIKit)
import UIKit
#endif

extension MapCoordinatorTests {
    #if canImport(UIKit)
    private enum Slope {
        static let longitude: Double = -122.0300
        static let south: Double = 37.3300
        static let north: Double = 37.3400
    }

    /// The accent colour's variant for one appearance, as RGBA.
    private static func accent(_ style: UIUserInterfaceStyle) -> [CGFloat] {
        UIColor(Color.accentColor)
            .resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
            .cgColor.components ?? []
    }

    /// A two-stop draft on a map shown in `style`, with its leg's renderer
    /// and its start pin's view.
    private func draft(
        on style: UIUserInterfaceStyle,
        _ coordinator: MapView.Coordinator
    ) async throws -> (MKMapView, MKPolylineRenderer, MKAnnotationView) {
        let map = makeMap(mapView(), coordinator)
        map.overrideUserInterfaceStyle = style
        trailMaker.setEditing(true)
        for latitude in [Slope.south, Slope.north] {
            trailMaker.appendWaypoint(at: CLLocationCoordinate2D(latitude: latitude, longitude: Slope.longitude))
        }
        await settle(until: "the draft's line to be drawn") {
            !coordinator.trailDraftOverlays.isEmpty
        }
        let line = try #require(coordinator.trailDraftOverlays.first)
        let renderer = try #require(coordinator.mapView(map, rendererFor: line) as? MKPolylineRenderer)
        let pin = try #require(coordinator.trailDraftAnnotations.first)
        let view = try #require(coordinator.mapView(map, viewFor: pin))
        return (map, renderer, view)
    }

    @Test(
        "the draft's line and pins are the accent variant the map is showing",
        arguments: [UIUserInterfaceStyle.light, .dark]
    )
    func draftTintFollowsTheMap(style: UIUserInterfaceStyle) async throws {
        let expected = Self.accent(style)
        #expect(Self.accent(.light) != Self.accent(.dark), "the accent colour has no dark variant to tell apart")
        let coordinator = MapView.Coordinator()
        let (map, renderer, pin) = try await draft(on: style, coordinator)
        defer { detach(map) }

        #expect(renderer.strokeColor?.cgColor.components == expected)
        #expect(pin.layer.backgroundColor?.components == expected)
    }

    /// A stop picked in the search sheet is put down while that sheet is over
    /// the map, and UIKit dims every tint behind a presented sheet. A pin
    /// resolved then kept the grey for good — its layer holds a `CGColor`,
    /// which nothing un-dims when the sheet goes.
    @Test("a pin made while a sheet dims the map is still the accent colour")
    func draftTintIgnoresADimmedMap() async throws {
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(), coordinator)
        map.overrideUserInterfaceStyle = .light
        map.tintAdjustmentMode = .dimmed
        defer { detach(map) }
        trailMaker.setEditing(true)
        for latitude in [Slope.south, Slope.north] {
            trailMaker.appendWaypoint(at: CLLocationCoordinate2D(latitude: latitude, longitude: Slope.longitude))
        }
        await settle(until: "the draft's line to be drawn") {
            !coordinator.trailDraftOverlays.isEmpty
        }
        let pin = try #require(coordinator.trailDraftAnnotations.first)
        let view = try #require(coordinator.mapView(map, viewFor: pin))

        #expect(view.layer.backgroundColor?.components == Self.accent(.light))
    }
    #endif
}
