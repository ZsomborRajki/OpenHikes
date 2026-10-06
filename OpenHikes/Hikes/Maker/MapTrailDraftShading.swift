//
//  MapTrailDraftShading.swift
//  OpenHikes
//
//  The trail being drawn, coloured by difficulty or steepness — see
//  ``TrailDraftShading`` for where the colours come from, and the *Color By*
//  control every hike shares (``RouteShading/coloring``) for which of them
//  is drawn.
//
//  One overlay over the whole line rather than a colour per leg, because a
//  coloured stretch does not stop where a leg does. It is a
//  ``DirectionalPolylineRenderer`` with a clear stroke, so it draws the
//  stretches, blended where they meet, and nothing else: where a stretch has
//  no colour, the leg beneath shows through in the accent colour, dashed or
//  solid as its state says. It sits above the legs — a leg added while it is
//  up goes in under it, see ``addTrailDraftLegLine(_:to:)``.
//
//  Taken off while a point is held or a leg is still being routed, because
//  either way the line under it is moving and the colours are about the line
//  as it was.
//

import MapKit
import OpenHikesData
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// What the map has drawn of the trail's colours.
struct TrailDraftShadeLayer {
    /// The overlay the stretches are drawn by, while there are any to draw.
    var line: MKPolyline?
    /// What ``line`` was drawn from, so a pass that changes none of it
    /// leaves the overlay alone.
    var drawn: Drawn?
    /// Guards the registration, for the reason ``MapView/Coordinator/isObservingTrailDraft``
    /// guards its own.
    var isObserving = false
    /// Read again when a drag starts or ends, which no observation reports.
    weak var controller: TrailDraftController?
    weak var coloring: RouteShading?

    struct Drawn: Equatable {
        let revision: Int
        let coloring: RouteColoring
    }
}

extension MapView.Coordinator {
    /// Observes the trail's colours and which of them is wanted, and redraws
    /// the overlay, then re-registers. Idempotent, like every registration
    /// here.
    func observeTrailDraftShading(
        _ controller: TrailDraftController,
        coloring: RouteShading,
        on mapView: MKMapView
    ) {
        guard !trailDraftShades.isObserving else { return }
        trailDraftShades.isObserving = true
        trailDraftShades.controller = controller
        trailDraftShades.coloring = coloring
        trackTrailDraftShading(controller, on: mapView)
    }

    private func trackTrailDraftShading(_ controller: TrailDraftController, on mapView: MKMapView) {
        refreshTrailDraftShades(on: mapView)
        reobserving(self, mapView, controller) {
            _ = controller.isEditing
            _ = controller.shading.revision
            _ = controller.draft.travelMode
            // The legs, for whether one is being routed. A pass for a leg
            // that changed nothing here costs one comparison.
            _ = controller.draft.legs
            _ = self.trailDraftShades.coloring?.coloring
        } onChange: { coordinator, map, model in
            coordinator.trackTrailDraftShading(model, on: map)
        }
    }

    /// Brings the overlay up to the colours, touching it only when what it
    /// would draw has changed.
    func refreshTrailDraftShades(on mapView: MKMapView) {
        let drawn = trailDraftShadesWanted()
        guard drawn != trailDraftShades.drawn else { return }
        trailDraftShades.drawn = drawn
        if let line = trailDraftShades.line {
            mapView.removeOverlay(line)
            trailDraftShades.line = nil
        }
        guard let drawn, let controller = trailDraftShades.controller else { return }
        let coordinates = controller.shading.stretches(for: drawn.coloring).flatMap(\.coordinates)
        guard coordinates.count > 1 else { return }
        let line = MKPolyline(coordinates: coordinates, count: coordinates.count)
        trailDraftShades.line = line
        mapView.addOverlay(line, level: .aboveLabels)
    }

    /// What the overlay should be drawn from, or `nil` for no overlay.
    private func trailDraftShadesWanted() -> TrailDraftShadeLayer.Drawn? {
        guard let controller = trailDraftShades.controller,
              let coloring = trailDraftShades.coloring?.coloring,
              controller.isEditing,
              controller.draft.travelMode == .hiking,
              !controller.draft.isRouting,
              trailDraftDrag == nil,
              !controller.shading.stretches(for: coloring).isEmpty
        else { return nil }
        return TrailDraftShadeLayer.Drawn(revision: controller.shading.revision, coloring: coloring)
    }

    /// One leg's line, onto the map under the trail's colours when they are
    /// up, so a leg that changes never covers them.
    func addTrailDraftLegLine(_ line: MKPolyline, to mapView: MKMapView) {
        if let shaded = trailDraftShades.line {
            mapView.insertOverlay(line, below: shaded)
        } else {
            mapView.addOverlay(line, level: .aboveLabels)
        }
    }

    /// The overlay's renderer, or `nil` when this polyline is not it.
    func trailDraftShadeRenderer(for polyline: MKPolyline) -> DirectionalPolylineRenderer? {
        guard polyline === trailDraftShades.line,
              let drawn = trailDraftShades.drawn,
              let controller = trailDraftShades.controller else { return nil }
        let renderer = DirectionalPolylineRenderer(polyline: polyline)
        renderer.pattern = .solid
        renderer.lineWidth = Self.trailDraftLineWidth
        renderer.lineJoin = .round
        renderer.lineCap = .round
        // Clear, so only the stretches are drawn — see the file header.
        renderer.strokeColor = .clear
        renderer.setShades(
            controller.shading.stretches(for: drawn.coloring).map { stretch in
                DirectionalPolylineRenderer.Shade(
                    polyline: MKPolyline(coordinates: stretch.coordinates, count: stretch.coordinates.count),
                    color: Self.trailDraftShadeColor(stretch.shade)
                )
            }
        )
        return renderer
    }

    #if canImport(UIKit)
    private static func trailDraftShadeColor(_ shade: RouteShade) -> CGColor { UIColor(shade.color).cgColor }
    #else
    private static func trailDraftShadeColor(_ shade: RouteShade) -> CGColor { NSColor(shade.color).cgColor }
    #endif
}
