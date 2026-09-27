//
//  MapCoordinator+DifficultyShading.swift
//  OpenHikes
//
//  The selected hike's line, coloured by the SAC grade of each stretch — see
//  ``RouteDifficultyShading`` for where the grades come from, and
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
    func observeRouteDifficulty(_ shading: RouteDifficultyShading, on mapView: MKMapView) {
        applyRouteDifficulty(shading)
        reobserving(self, mapView, shading) {
            _ = shading.revision
        } onChange: { coordinator, _, model in
            coordinator.observeRouteDifficulty(model, on: mapView)
        }
    }

    /// Keeps the stretches as polylines, built once per answer rather than
    /// once per restyle, and recolours the line with them.
    func applyRouteDifficulty(_ shading: RouteDifficultyShading) {
        difficultyHikeID = shading.hikeID
        difficultyStretches = shading.stretches.map { stretch in
            (stretch.difficulty, MKPolyline(coordinates: stretch.coordinates, count: stretch.coordinates.count))
        }
        applyDifficultyShades()
    }

    /// Hands the live line the stretches that belong to it, in each grade's
    /// own colour at the line's alpha — or none, when the stretches were
    /// measured along some other hike than the one drawn.
    ///
    /// The grade's colour is the Difficulty section's (``TrailDifficulty/color``),
    /// so the map and the bar under it are read with one legend.
    func applyDifficultyShades() {
        guard let renderer = routeRenderer as? DirectionalPolylineRenderer else { return }
        let belongs = difficultyHikeID != nil && difficultyHikeID == routeID
        let alpha = Self.alpha(of: routeTint)
        let shades = belongs
            ? difficultyStretches.map { stretch in
                DirectionalPolylineRenderer.Shade(
                    polyline: stretch.polyline,
                    color: Self.platformColor(stretch.difficulty.color)
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
