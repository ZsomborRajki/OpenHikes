//
//  MapCoordinator+CountryOutlines.swift
//  OpenHikes
//
//  *Offline Maps*' half of the map: an outline round every country it lists,
//  filled where the country is downloaded and drawn bolder where its row is
//  chosen. See ``OfflineCountryOutlines``.
//
//  Drawn under every line, so a hike stays readable over a country, and
//  rebuilt wholesale when the list changes: a dozen polygons of a hundred
//  points each, a few times a visit.
//

import MapKit

/// One ring of a country's outline, knowing whose it is.
nonisolated final class OfflineCountryPolygon: MKPolygon {
    private(set) var countryID = ""

    static func make(countryID: String, ring: [[Double]]) -> OfflineCountryPolygon {
        var coordinates = ring.compactMap { pair -> CLLocationCoordinate2D? in
            guard pair.count >= 2 else { return nil }
            return CLLocationCoordinate2D(latitude: pair[1], longitude: pair[0])
        }
        let polygon = OfflineCountryPolygon(coordinates: &coordinates, count: coordinates.count)
        polygon.countryID = countryID
        return polygon
    }
}

struct CountryOutlineMapState {
    var polygons: [OfflineCountryPolygon] = []
    var renderers: [ObjectIdentifier: MKPolygonRenderer] = [:]
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
        let drawnIDs = countryOutlineMap.polygons.map(\.countryID)
        let wantedIDs = shown.flatMap { country in country.outline.map { _ in country.id } }
        if drawnIDs != wantedIDs {
            mapView.removeOverlays(countryOutlineMap.polygons)
            countryOutlineMap.renderers = [:]
            countryOutlineMap.polygons = shown.flatMap { country in
                country.outline.map { OfflineCountryPolygon.make(countryID: country.id, ring: $0) }
            }
            // Over the map's own tiles and hiking routes, and under every
            // line, which all share their level.
            let ground = groundOverlayCount(on: mapView)
            for (index, polygon) in countryOutlineMap.polygons.enumerated() {
                mapView.insertOverlay(polygon, at: ground + index, level: .aboveLabels)
            }
        }
        for polygon in countryOutlineMap.polygons {
            if let renderer = countryOutlineMap.renderers[ObjectIdentifier(polygon)] {
                styleCountryOutline(renderer, for: polygon.countryID, outlines: outlines)
                renderer.setNeedsDisplay()
            }
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
        let renderer = MKPolygonRenderer(polygon: polygon)
        if let outlines = countryOutlineMap.outlines {
            styleCountryOutline(renderer, for: polygon.countryID, outlines: outlines)
        }
        countryOutlineMap.renderers[ObjectIdentifier(polygon)] = renderer
        return renderer
    }

    private func styleCountryOutline(_ renderer: MKPolygonRenderer, for id: String, outlines: OfflineCountryOutlines) {
        let isInstalled = outlines.installedIDs.contains(id)
        let isSelected = outlines.selectedID == id
        #if os(iOS)
        let tint = UIColor(named: "AccentColor") ?? .systemGreen
        renderer.strokeColor = isSelected || isInstalled ? tint : .secondaryLabel
        renderer.fillColor = tint.withAlphaComponent(
            isInstalled ? Self.installedFill : (isSelected ? Self.selectedFill : 0)
        )
        #endif
        renderer.lineWidth = isSelected ? Self.selectedOutlineWidth : Self.outlineWidth
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
