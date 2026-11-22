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

    /// Slovenia's outline as a later list corrects it, east of where the
    /// first list had it.
    private static let correctedSlovenia = OfflineCountryManifest.Bounds(
        west: 14.9, south: 45.4, east: 17.0, north: 46.9 // swiftlint:disable:this no_magic_numbers
    )

    /// A refreshed list can keep an area's id and place and correct its
    /// outline. A tap is tested against the list's outline, so the map must
    /// draw that one, or it chooses by a shape nobody can see.
    @Test("a list that corrects an area's outline under the same id draws the new outline")
    func correctedOutlineIsDrawn() async throws {
        let outlines = OfflineCountryOutlines()
        var view = mapView()
        view.countryOutlines = outlines
        let coordinator = MapView.Coordinator()
        let map = makeMap(view, coordinator)
        defer { detach(map) }
        var chosen: [String] = []
        let token = outlines.attach { chosen.append($0) }
        var listed = Self.outlinedCountries()
        // Bounds that hold both outlines, as a tap tests the bounds first:
        // only the outline decides which of the two points is Slovenia's.
        listed[1].bounds.east = Self.correctedSlovenia.east
        outlines.show(listed, installed: [], selected: nil, token: token)
        map.setRegion(listed[1].bounds.framingRegion, animated: false)
        await settleDelegateHop(until: "both countries are outlined") { polygons(on: map).count == 2 }
        let earlier = try #require(polygons(on: map).first { $0.countryID == "SI" })
        let ljubljana = CLLocationCoordinate2D(latitude: 46.05, longitude: 14.5)
        let eastOfTheFirstOutline = CLLocationCoordinate2D(latitude: 46.05, longitude: 16.8)
        let tap = { coordinator.handleCountryOutlineTap(at: map.convert($0, toPointTo: map), in: map) }
        #expect(!tap(eastOfTheFirstOutline), "precondition: the first outline stops short of it")

        listed[1].outline = OfflineCountryFixture.outline(of: Self.correctedSlovenia)
        outlines.show(listed, installed: [], selected: nil, token: token)
        await settleDelegateHop(until: "Slovenia is outlined again") {
            polygons(on: map).contains { $0.countryID == "SI" && $0 !== earlier }
        }

        let slovenia = try #require(polygons(on: map).first { $0.countryID == "SI" })
        #expect(slovenia.boundingMapRect.contains(MKMapPoint(eastOfTheFirstOutline)))
        #expect(!slovenia.boundingMapRect.contains(MKMapPoint(ljubljana)))
        #expect(tap(eastOfTheFirstOutline), "a tap where the new outline is drawn chooses it")
        #expect(!tap(ljubljana), "and where only the old one was, chooses nothing")
        #expect(chosen == ["SI"])
        #expect(polygons(on: map).map(\.countryID) == ["AT", "SI"], "in the list's order, and only once")
    }

    /// A list read again, as a catalog refresh reads it, holds equal
    /// outlines in new storage, and a new build changes nothing drawn: the
    /// overlays stay, and choosing a row restyles the one it chose.
    @Test("a list read again with the same outlines keeps its overlays and only restyles")
    func unchangedOutlinesAreKept() async throws {
        let outlines = OfflineCountryOutlines()
        var view = mapView()
        view.countryOutlines = outlines
        let coordinator = MapView.Coordinator()
        let map = makeMap(view, coordinator)
        defer { detach(map) }
        let token = outlines.attach { _ in /* nothing chosen here */ }
        outlines.show(Self.outlinedCountries(), installed: [], selected: nil, token: token)
        await settleDelegateHop(until: "both countries are outlined") { polygons(on: map).count == 2 }
        let drawn = polygons(on: map)
        let austria = try #require(drawn.first { $0.countryID == "AT" })
        let renderer = try #require(coordinator.mapView(map, rendererFor: austria) as? MKMultiPolygonRenderer)
        let plainWidth = renderer.lineWidth

        var refreshed = Self.outlinedCountries()
        refreshed[0].build = "20261231"
        outlines.show(refreshed, installed: [], selected: "AT", token: token)
        await settleDelegateHop(until: "the chosen country is drawn bolder") { renderer.lineWidth > plainWidth }

        #expect(polygons(on: map).elementsEqual(drawn) { $0 === $1 })
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
        map.setRegion(OfflineCountryFixture.country(bytes: Data("SI".utf8)).framingRegion, animated: false)

        let ljubljana = map.convert(CLLocationCoordinate2D(latitude: 46.05, longitude: 14.5), toPointTo: map)
        #expect(coordinator.handleCountryOutlineTap(at: ljubljana, in: map))
        #expect(chosen == ["SI"])

        outlines.detach(token: token)
        #expect(!coordinator.handleCountryOutlineTap(at: ljubljana, in: map))
    }

    /// The camera move a row's tap makes, as MapKit reads it back: a frame
    /// across the date line holding both of the area's islands, not the
    /// world.
    @Test("an area across the antimeridian is shown round itself")
    func showsAnAreaAcrossTheAntimeridian() {
        let coordinator = MapView.Coordinator()
        let view = mapView()
        let map = makeMap(view, coordinator)
        defer { detach(map) }
        view.update(map, coordinator)
        let fiji = OfflineCountryFixture.dateLineCountry(bytes: Data("FJ".utf8))

        coordinator.show(fiji.framingRegion, on: map, animated: false)

        #expect(map.region.span.longitudeDelta < 30, "a frame round the area, not round the world")
        for island in [
            CLLocationCoordinate2D(latitude: -18, longitude: 178.5),
            CLLocationCoordinate2D(latitude: -17.25, longitude: -179.25),
        ] {
            let point = map.convert(island, toPointTo: map)
            #expect(map.bounds.contains(point), "both islands are on screen")
        }
    }
}
#endif
