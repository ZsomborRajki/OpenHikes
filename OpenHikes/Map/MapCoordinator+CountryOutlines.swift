//
//  MapCoordinator+CountryOutlines.swift
//  OpenHikes
//
//  *Offline Maps*' half of the map: an outline round every country it lists,
//  filled where the country is downloaded and drawn bolder where its row is
//  chosen. See ``OfflineCountryOutlines``.
//
//  Drawn under every line, so a hike stays readable over a country. The list
//  is every country and region, some four hundred areas and two and a half
//  thousand rings, an area of islands — Nunavut, Indonesia — hundreds on its
//  own. So an area is one overlay and one renderer, not one a ring; the
//  overlays are rebuilt only when the areas listed change; and choosing a
//  row draws again only the areas whose look it changed.
//

import MapKit

/// A country's outline, every ring of it, knowing whose it is.
nonisolated final class OfflineCountryPolygon: MKMultiPolygon {
    private(set) var countryID = ""

    static func make(countryID: String, outline: [[[Double]]]) -> OfflineCountryPolygon {
        let rings = outline.map { ring in
            var coordinates = ring.compactMap { pair -> CLLocationCoordinate2D? in
                guard pair.count >= 2 else { return nil }
                return CLLocationCoordinate2D(latitude: pair[1], longitude: pair[0])
            }
            return MKPolygon(coordinates: &coordinates, count: coordinates.count)
        }
        let polygon = OfflineCountryPolygon(rings)
        polygon.countryID = countryID
        return polygon
    }
}

struct CountryOutlineMapState {
    /// How an area's outline is drawn.
    struct Look: Equatable {
        var isInstalled: Bool
        var isSelected: Bool
    }

    var polygons: [OfflineCountryPolygon] = []
    var renderers: [ObjectIdentifier: MKMultiPolygonRenderer] = [:]
    /// How each area was last drawn, so a change draws again only those whose
    /// look it changed.
    var looks: [String: Look] = [:]
    var isObserving = false
    weak var outlines: OfflineCountryOutlines?
}

extension MapView.Coordinator {
    func observeCountryOutlines(_ outlines: OfflineCountryOutlines, on mapView: MKMapView) {
        guard !countryOutlineMap.isObserving else { return }
        countryOutlineMap.isObserving = true
        countryOutlineMap.outlines = outlines
        trackCountryOutlines(outlines, on: mapView)
    }

    private func trackCountryOutlines(_ outlines: OfflineCountryOutlines, on mapView: MKMapView) {
        applyCountryOutlines(outlines, on: mapView)
        reobserving(self, mapView, outlines) {
            _ = outlines.isActive
            _ = outlines.countries
            _ = outlines.installedIDs
            _ = outlines.selectedID
        } onChange: { coordinator, map, model in
            coordinator.trackCountryOutlines(model, on: map)
        }
    }

    private func applyCountryOutlines(_ outlines: OfflineCountryOutlines, on mapView: MKMapView) {
        let shown = outlines.isActive ? outlines.countries : []
        if countryOutlineMap.polygons.map(\.countryID) != shown.map(\.id) {
            mapView.removeOverlays(countryOutlineMap.polygons)
            countryOutlineMap.renderers = [:]
            countryOutlineMap.looks = [:]
            countryOutlineMap.polygons = shown.map { country in
                OfflineCountryPolygon.make(countryID: country.id, outline: country.outline)
            }
            // Over the map's own tiles and hiking routes, and under every
            // line, which all share their level.
            let ground = groundOverlayCount(on: mapView)
            for (index, polygon) in countryOutlineMap.polygons.enumerated() {
                mapView.insertOverlay(polygon, at: ground + index, level: .aboveLabels)
            }
        }
        for polygon in countryOutlineMap.polygons {
            let look = Self.countryOutlineLook(of: polygon.countryID, outlines: outlines)
            guard countryOutlineMap.looks[polygon.countryID] != look,
                  let renderer = countryOutlineMap.renderers[ObjectIdentifier(polygon)]
            else { continue }
            style(renderer, as: look, for: polygon.countryID)
            renderer.setNeedsDisplay()
        }
    }

    /// How many overlays at the bottom are the map itself: its tiles and the
    /// hiking routes over them, which the outlines go above.
    private func groundOverlayCount(on mapView: MKMapView) -> Int {
        mapView.overlays(in: .aboveLabels).prefix { $0 is TileOverlay || $0 is HikingRoutesOverlay }.count
    }

    /// The renderer for one of the outlines, or `nil` for any other overlay.
    func countryOutlineRenderer(for overlay: MKOverlay) -> MKOverlayRenderer? {
        guard let polygon = overlay as? OfflineCountryPolygon else { return nil }
        let renderer = MKMultiPolygonRenderer(multiPolygon: polygon)
        if let outlines = countryOutlineMap.outlines {
            let look = Self.countryOutlineLook(of: polygon.countryID, outlines: outlines)
            style(renderer, as: look, for: polygon.countryID)
        }
        countryOutlineMap.renderers[ObjectIdentifier(polygon)] = renderer
        return renderer
    }

    private static func countryOutlineLook(
        of id: String,
        outlines: OfflineCountryOutlines
    ) -> CountryOutlineMapState.Look {
        CountryOutlineMapState.Look(
            isInstalled: outlines.installedIDs.contains(id),
            isSelected: outlines.selectedID == id
        )
    }

    private func style(_ renderer: MKMultiPolygonRenderer, as look: CountryOutlineMapState.Look, for id: String) {
        countryOutlineMap.looks[id] = look
        #if os(iOS)
        let tint = UIColor(named: "AccentColor") ?? .systemGreen
        renderer.strokeColor = look.isSelected || look.isInstalled ? tint : .secondaryLabel
        renderer.fillColor = tint.withAlphaComponent(
            look.isInstalled ? Self.installedFill : (look.isSelected ? Self.selectedFill : 0)
        )
        #endif
        renderer.lineWidth = look.isSelected ? Self.selectedOutlineWidth : Self.outlineWidth
    }

    /// A tap on the map while *Offline Maps* is up: the country under it.
    func handleCountryOutlineTap(at point: CGPoint, in mapView: MKMapView) -> Bool {
        guard let outlines = countryOutlineMap.outlines, outlines.isActive else { return false }
        return outlines.select(at: mapView.convert(point, toCoordinateFrom: mapView))
    }

    private static let outlineWidth: CGFloat = 1.5
    private static let selectedOutlineWidth: CGFloat = 3
    private static let installedFill: CGFloat = 0.22
    private static let selectedFill: CGFloat = 0.1
}
