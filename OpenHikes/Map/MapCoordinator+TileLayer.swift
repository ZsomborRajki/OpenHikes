//
//  MapCoordinator+TileLayer.swift
//  OpenHikes
//
//  The hiking-route layer's place on the map: one `TileOverlay` that draws
//  over the selected map rather than replacing it, sitting directly on top of
//  the base tiles and beneath every line the app draws.
//
//  `.aboveLabels`, the level the base tiles and every line already share,
//  because a level is a canvas — see `MapCommunityRoutes.swift` for what a
//  line put one level down turned into. Within it the order is by index:
//  the base tiles at the bottom (re-inserted `at: 0` by
//  `MapView.applyTileSource` whenever the map changes, so they stay
//  underneath this by their own doing), then this layer, then the shared
//  hikes' lines and the hiker's own. Those two ask ``groundOverlay`` for the
//  floor they go above, so a layer switched on with a route already drawn
//  slides in under it rather than over it.
//

import MapKit

extension MapView.Coordinator {
    /// The topmost tile overlay — the layer when one is drawn, otherwise the
    /// base map's tiles — or `nil` over Apple's map with no layer. What every
    /// line on the map is inserted above.
    var groundOverlay: TileOverlay? { layerOverlay ?? tileOverlay }

    /// Installs `layer` over the map, replaces a different one, or removes it.
    ///
    /// - Returns: whether anything changed, so the caller re-credits the map
    ///   only when it did.
    @discardableResult func applyTileLayer(_ layer: TileLayer?, on mapView: MKMapView) -> Bool {
        // The empty string for "no layer", so the first pass of a map built
        // with the switch off is a change from `nil` and is remembered, and
        // every pass after it is free.
        let key = layer?.id ?? ""
        guard tileLayerKey != key else { return false }
        tileLayerKey = key

        if let existing = layerOverlay {
            mapView.removeOverlay(existing)
            layerOverlay = nil
        }
        guard let layer else { return true }

        let overlay = TileOverlay(providerID: layer.id, urlTemplate: layer.urlTemplate)
        // Transparent tiles over a map, not a map: leaving this off is what
        // keeps Apple's base map drawn underneath when it is the selection.
        overlay.canReplaceMapContent = false
        overlay.minimumZ = layer.minimumZ
        overlay.maximumZ = layer.maximumZ
        if let tileOverlay {
            mapView.insertOverlay(overlay, above: tileOverlay)
        } else {
            mapView.insertOverlay(overlay, at: 0, level: .aboveLabels)
        }
        layerOverlay = overlay
        return true
    }
}
