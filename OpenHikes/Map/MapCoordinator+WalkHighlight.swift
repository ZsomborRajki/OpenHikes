//
//  MapCoordinator+WalkHighlight.swift
//  OpenHikes
//
//  The stretches a finished walk covered, drawn over the route it was walked
//  along when the Walk Summary asks for them.
//
//  Split out of `MapCoordinator.swift` for the reason the highlight dot and
//  the tracking button were: the coordinator's own file is the observation
//  plumbing, and each thing it drives reads better beside its own argument.
//  Internal rather than private, which is what a file split costs in Swift.
//

import MapKit
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

extension MapView.Coordinator {
    /// Wider than the route, so a covered stretch reads as sitting on top of
    /// the line rather than replacing it.
    private static let walkLineWidthFactor: CGFloat = 1.6
    /// Wider still, for the casing that separates the stretch from the route
    /// underneath: without it a tinted line over a tinted line is one line.
    private static let walkCasingWidthFactor: CGFloat = 2.6
    private static let walkCasingAlpha: CGFloat = 0.9

    /// Observes `highlight.revision` and applies the stretches imperatively,
    /// then re-registers — the same shape as `observeHighlight(_:on:)`.
    func observeWalkHighlight(_ highlight: WalkHighlight, on mapView: MKMapView) {
        applyWalkHighlight(highlight.segments, on: mapView)
        withObservationTracking {
            _ = highlight.revision
        } onChange: { [weak self, weak mapView, weak highlight] in
            let coordinator = self
            let map = mapView
            let model = highlight
            Task { @MainActor in
                guard let coordinator, let map, let model else { return }
                coordinator.observeWalkHighlight(model, on: map)
            }
        }
    }

    /// Replaces whatever stretches are drawn with `segments`. O(stretches),
    /// and a walk has as many as it has gaps.
    func applyWalkHighlight(_ segments: [[CLLocationCoordinate2D]], on mapView: MKMapView) {
        if !walkHighlightOverlays.isEmpty || !walkHighlightCasingOverlays.isEmpty {
            mapView.removeOverlays(walkHighlightCasingOverlays + walkHighlightOverlays)
            walkHighlightCasingOverlays = []
            walkHighlightOverlays = []
        }
        guard !segments.isEmpty else { return }
        RenderSignpost.mark("MapWalkHighlightApplied", "\(segments.count) stretches")
        let casings = segments.map { stretch in MKPolyline(coordinates: stretch, count: stretch.count) }
        let lines = segments.map { stretch in MKPolyline(coordinates: stretch, count: stretch.count) }
        walkHighlightCasingOverlays = casings
        walkHighlightOverlays = lines
        // Casings first, then lines, both at the top of the level the route
        // is drawn at: the stretch has to sit over the route, and the line
        // over its own casing.
        mapView.addOverlays(casings, level: .aboveLabels)
        mapView.addOverlays(lines, level: .aboveLabels)
    }

    /// The renderer for one of the walk's overlays, or `nil` for a polyline
    /// that is not one — which is what lets `rendererFor` ask this first and
    /// carry on to the route styles otherwise.
    func walkHighlightRenderer(for polyline: MKPolyline) -> MKPolylineRenderer? {
        if walkHighlightCasingOverlays.contains(where: { $0 === polyline }) {
            let renderer = MKPolylineRenderer(polyline: polyline)
            #if os(macOS)
            renderer.strokeColor = NSColor.white.withAlphaComponent(Self.walkCasingAlpha)
            #else
            renderer.strokeColor = UIColor.white.withAlphaComponent(Self.walkCasingAlpha)
            #endif
            renderer.lineWidth = CGFloat(routeWidth) * Self.walkCasingWidthFactor
            renderer.lineJoin = .round
            renderer.lineCap = .round
            return renderer
        }
        if walkHighlightOverlays.contains(where: { $0 === polyline }) {
            let renderer = MKPolylineRenderer(polyline: polyline)
            // The route's own tint, at full strength whatever alpha the
            // walker gave the line: this is the part of it they walked.
            #if os(macOS)
            renderer.strokeColor = NSColor(routeTint).withAlphaComponent(1)
            #else
            renderer.strokeColor = UIColor(routeTint).withAlphaComponent(1)
            #endif
            renderer.lineWidth = CGFloat(routeWidth) * Self.walkLineWidthFactor
            renderer.lineJoin = .round
            renderer.lineCap = .round
            return renderer
        }
        return nil
    }
}
