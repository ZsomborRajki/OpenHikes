//
//  MapTrailDraftTint.swift
//  OpenHikes
//
//  The colour the trail being drawn is drawn in, taken from the map rather
//  than from the app.
//
//  The maker draws in the accent colour, which has a dark variant — a bright
//  green meant for dark surfaces. Over the raster tiles the map is forced
//  light (see `MapView.updateTileOverlay`), because every one of them draws a
//  light page at every hour, and the UIKit chrome on the map follows that: the
//  tracking glyph and the travel-time bubble come out the deep green. The
//  polyline renderers and the pins' layers did not. A renderer's stroke and a
//  layer's `CGColor` are resolved against whatever appearance is current when
//  they are drawn, which is the app's, so a dark-mode phone drew the neon
//  line over light OpenStreetMap tiles next to a deep-green button.
//
//  So each of them is resolved against the map view's own traits here, and
//  redrawn when those traits change. One registration covers both ways that
//  happens — the hiker switching tiles, which moves the map's override, and
//  the phone turning over while Apple's own map is drawn, which the map
//  follows — so the neon line is what Apple Maps in dark mode gets and
//  nothing else does.
//

import MapKit
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

extension MapView.Coordinator {
    #if canImport(UIKit)
    /// The accent colour as this map is showing it: deep green over light
    /// tiles, bright green over Apple's map in dark mode.
    ///
    /// The override is read before the traits because the traits take it in
    /// on the next layout pass, and a renderer asked for in between would be
    /// resolved against the appearance the map is leaving.
    static func trailDraftTint(on mapView: MKMapView) -> UIColor {
        let override = mapView.overrideUserInterfaceStyle
        let traits = override == .unspecified
            ? mapView.traitCollection
            : mapView.traitCollection.modifyingTraits { $0.userInterfaceStyle = override }
        return UIColor(Color.accentColor).resolvedColor(with: traits)
    }

    /// Redraws the trail being drawn in the colour the map now calls for.
    ///
    /// Only what holds a resolved colour: the travel-time bubbles are views on
    /// the map, and resolve against it on their own. A leg or pin with no
    /// renderer or view yet takes the colour when MapKit asks for one.
    func refreshTrailDraftTint(on mapView: MKMapView) {
        let tint = Self.trailDraftTint(on: mapView)
        for line in trailDraftOverlays {
            guard let renderer = mapView.renderer(for: line) as? MKPolylineRenderer else { continue }
            renderer.strokeColor = tint
            renderer.setNeedsDisplay()
        }
        let alternative = tint.withAlphaComponent(Self.alternativeLineAlpha)
        for line in trailDraftRouteChoices.lines {
            guard let renderer = mapView.renderer(for: line) as? MKPolylineRenderer else { continue }
            renderer.strokeColor = alternative
            renderer.setNeedsDisplay()
        }
        for pin in trailDraftAnnotations {
            mapView.view(for: pin)?.layer.backgroundColor = tint.cgColor
        }
    }

    /// Keeps the draft's colour following the map's appearance for as long as
    /// the map lives. See the file header.
    func observeTrailDraftTint(on mapView: MKMapView) {
        mapView.registerForTraitChanges(
            [UITraitUserInterfaceStyle.self]
        ) { [weak self] (map: MKMapView, _: UITraitCollection) in
            self?.refreshTrailDraftTint(on: map)
        }
    }
    #endif
}
