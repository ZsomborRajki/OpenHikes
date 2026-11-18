//
//  MapCoordinatorTests+CountryOutlines.swift
//  OpenHikesTests
//
//  *Offline Maps*' half of the map: an outline round every country it
//  lists while its screen holds the map, filled where the country is
//  downloaded, bolder where its row is chosen, drawn over the map's own
//  tiles, and gone with the screen.
//

import Foundation
import MapKit
@testable import OpenHikes
import Testing

#if os(iOS)
extension MapCoordinatorTests {
    /// A second ring of Austria's, inside its bounds.
    private static let austrianIsland = OfflineCountryManifest.Bounds(
        west: 9.6, south: 48.0, east: 9.8, north: 48.2 // swiftlint:disable:this no_magic_numbers
    )

    /// Austria with an island of its own, as an area of many rings is: one
    /// overlay the area, not one a ring.
    private static func outlinedCountries() -> [OfflineCountryManifest.Country] {
        var austria = OfflineCountryFixture.northernCountry(bytes: Data("AT".utf8))
        austria.outline += OfflineCountryFixture.outline(of: austrianIsland)
        return [austria, OfflineCountryFixture.country(bytes: Data("SI".utf8), id: "SI")]
    }

    private func polygons(on map: MKMapView) -> [OfflineCountryPolygon] {
        map.overlays.compactMap { $0 as? OfflineCountryPolygon }
    }

    @Test("Offline Maps' outlines are drawn over the tiles while its screen holds the map")
    func outlinesFollowTheScreen() async throws {
        let outlines = OfflineCountryOutlines()
        var view = mapView()
        view.countryOutlines = outlines
        let coordinator = MapView.Coordinator()
        let map = makeMap(view, coordinator)
        defer { detach(map) }
        #expect(polygons(on: map).isEmpty, "precondition: nothing outlined before the screen")

        let token = outlines.attach { _ in /* nothing chosen here */ }
        outlines.show(Self.outlinedCountries(), installed: ["SI"], selected: nil, token: token)
        await settleDelegateHop(until: "both countries are outlined") { polygons(on: map).count == 2 }

        let level = map.overlays(in: .aboveLabels)
        let lastTile = try #require(level.lastIndex { $0 is TileOverlay })
        let firstOutline = try #require(level.firstIndex { $0 is OfflineCountryPolygon })
        #expect(firstOutline > lastTile, "over the map's own tiles")

        outlines.detach(token: token)
        await settleDelegateHop(until: "the outlines go with the screen") { polygons(on: map).isEmpty }
    }

    @Test("a downloaded country is filled, and the chosen one drawn bolder")
    func outlineStyles() async throws {
        let outlines = OfflineCountryOutlines()
        var view = mapView()
        view.countryOutlines = outlines
        let coordinator = MapView.Coordinator()
        let map = makeMap(view, coordinator)
        defer { detach(map) }
        let token = outlines.attach { _ in /* nothing chosen here */ }
        outlines.show(Self.outlinedCountries(), installed: ["SI"], selected: nil, token: token)
        await settleDelegateHop(until: "both countries are outlined") { polygons(on: map).count == 2 }
        let austria = try #require(polygons(on: map).first { $0.countryID == "AT" })
        let slovenia = try #require(polygons(on: map).first { $0.countryID == "SI" })
        let austriaRenderer = try #require(coordinator.mapView(map, rendererFor: austria) as? MKMultiPolygonRenderer)
        let sloveniaRenderer = try #require(coordinator.mapView(map, rendererFor: slovenia) as? MKMultiPolygonRenderer)

        #expect(austriaRenderer.fillColor?.cgColor.alpha == 0)
        #expect((sloveniaRenderer.fillColor?.cgColor.alpha ?? 0) > 0)
        let plainWidth = austriaRenderer.lineWidth

        outlines.show(Self.outlinedCountries(), installed: ["SI"], selected: "AT", token: token)
        await settleDelegateHop(until: "the chosen country is drawn bolder") {
            austriaRenderer.lineWidth > plainWidth
        }
        #expect(sloveniaRenderer.lineWidth == plainWidth)
    }

    @Test("a tap inside an outline chooses that country, and outside one is the map's")
    func tapChoosesACountry() {
        let outlines = OfflineCountryOutlines()
        var view = mapView()
        view.countryOutlines = outlines
        let coordinator = MapView.Coordinator()
        let map = makeMap(view, coordinator)
        defer { detach(map) }
        var chosen: [String] = []
        let token = outlines.attach { chosen.append($0) }
        outlines.show(Self.outlinedCountries(), installed: [], selected: nil, token: token)
        map.setRegion(OfflineCountryFixture.bounds.framingRegion, animated: false)

        let ljubljana = map.convert(CLLocationCoordinate2D(latitude: 46.05, longitude: 14.5), toPointTo: map)
        #expect(coordinator.handleCountryOutlineTap(at: ljubljana, in: map))
        #expect(chosen == ["SI"])

        outlines.detach(token: token)
        #expect(!coordinator.handleCountryOutlineTap(at: ljubljana, in: map))
    }
}
#endif
