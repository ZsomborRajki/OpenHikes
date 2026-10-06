//
//  MapCoordinator+RouteShading.swift
//  OpenHikes
//
//  The selected hike's line, coloured stretch by stretch — see
//  ``RouteShading`` for where the stretches come from, and
//  ``DirectionalPolylineRenderer`` for how a stretch is drawn into the line
//  rather than over it.
//
//  Split out of `MapCoordinator.swift` for the reason the walk's stretches
//  were: that file is the observation plumbing, and it had reached its
//  length. Internal rather than private, which is what a file split costs in
//  Swift — `rendererFor` and the style observer next door call these.
//

import MapKit
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

extension MapView.Coordinator {
    /// Observes `shading.revision` and hands the stretches to the line,
    /// then re-registers — the same shape as `observeWalkHighlight(_:on:)`.
    func observeRouteShading(_ shading: RouteShading, on mapView: MKMapView) {
        applyRouteShading(shading)
        reobserving(self, mapView, shading) {
            _ = shading.revision
        } onChange: { coordinator, _, model in
            coordinator.observeRouteShading(model, on: mapView)
        }
    }

    /// Keeps the stretches as polylines, built once per answer rather than
    /// once per restyle, and recolours the line with them.
    func applyRouteShading(_ shading: RouteShading) {
        shadedHikeID = shading.hikeID
        shadedStretches = shading.stretches.map { stretch in
            (stretch.shade, MKPolyline(coordinates: stretch.coordinates, count: stretch.coordinates.count))
        }
        applyRouteShades()
    }

    /// Hands the live line the stretches that belong to it, each in its
    /// step's colour at the line's alpha — or none, when the stretches were
    /// measured along some other hike than the one drawn.
    ///
    /// The colours are ``RouteShade``'s, which the Difficulty section's bar
    /// is drawn in too, so the map and the bar under it are read with one
    /// legend.
    func applyRouteShades() {
        guard let renderer = routeRenderer as? DirectionalPolylineRenderer else { return }
        let belongs = shadedHikeID != nil && shadedHikeID == routeID
        let alpha = Self.alpha(of: routeTint)
        let shades = belongs
            ? shadedStretches.map { stretch in
                DirectionalPolylineRenderer.Shade(
                    polyline: stretch.polyline,
                    color: Self.platformColor(stretch.shade.color)
                        .withAlphaComponent(alpha)
                        .cgColor
                )
            }
            : []
        renderer.setShades(shades)
        renderer.setNeedsDisplay()
    }

    private static func alpha(of color: Color) -> CGFloat {
        platformColor(color).cgColor.alpha
    }

    #if canImport(UIKit)
    private static func platformColor(_ color: Color) -> UIColor { UIColor(color) }
    #else
    private static func platformColor(_ color: Color) -> NSColor { NSColor(color) }
    #endif
}
