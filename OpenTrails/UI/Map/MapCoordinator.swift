//
//  MapCoordinator.swift
//  OpenTrails
//
//  MapView's MKMapViewDelegate: owns the map's overlays/annotations and
//  applies RouteHighlight/SheetMetrics/MapController/LocationManager changes
//  imperatively, keeping continuous updates entirely off SwiftUI's render path.
//

import SwiftUI
import MapKit

extension MapView {
    final class Coordinator: NSObject, MKMapViewDelegate {
        var hasCentered = false
        /// Guards `observeLocation` so `update(_:_:)` — called on every
        /// SwiftUI-driven pass — only starts the location-tracking loop once.
        private var isObservingLocation = false
        var routeID: UUID?
        var routeOverlay: MKPolyline?
        /// The live renderer for the route line, kept so a tint change can recolor
        /// it in place without rebuilding the overlay.
        weak var routeRenderer: MKPolylineRenderer?
        /// The currently installed tile overlay and a key identifying its source.
        var tileOverlay: TileOverlay?
        var tileSourceKey: String?
        var routeTint: Color = .green
        var routeWidth: Double = 5
        var highlightAnnotation: MKPointAnnotation?
        var trackingBottomConstraint: NSLayoutConstraint?
        private weak var sheetMetrics: SheetMetrics?
        /// Screen-point radius within which the selection dot and the "my location"
        /// puck are considered overlapping (roughly the size of either dot).
        static let overlapThresholdPoints: CGFloat = 20

        /// Edge padding used whenever the map is fitted to the route.
        #if os(macOS)
        static let routeInsets = NSEdgeInsets(top: 60, left: 60, bottom: 60, right: 60)
        #else
        static let routeInsets = UIEdgeInsets(top: 80, left: 60, bottom: 80, right: 60)
        #endif

        /// Applies the current tint (with its alpha) and width to the route line.
        func applyStyle(to renderer: MKPolylineRenderer) {
            #if os(macOS)
            renderer.strokeColor = NSColor(routeTint)
            #else
            renderer.strokeColor = UIColor(routeTint)
            #endif
            renderer.lineWidth = CGFloat(routeWidth)
        }

        /// Fits the currently drawn route into view. Shared by the initial draw and
        /// the detail view's Zoom button.
        func fitToCurrentRoute(_ mapView: MKMapView, animated: Bool) {
            guard let polyline = routeOverlay else { return }
            mapView.setVisibleMapRect(polyline.boundingMapRect, edgePadding: Self.routeInsets, animated: animated)
        }

        /// Observes the detail view / search commands and applies them imperatively.
        /// Each command re-registers only its own tracking (bumping one must not
        /// re-arm the others, or they'd multiply).
        func observeMapController(_ controller: MapController, on mapView: MKMapView) {
            observeFitRoute(controller, on: mapView)
            observeShowRegion(controller, on: mapView)
        }

        private func observeFitRoute(_ controller: MapController, on mapView: MKMapView) {
            withObservationTracking {
                _ = controller.fitRouteRequest
            } onChange: { [weak self, weak mapView, weak controller] in
                let coordinator = self
                let map = mapView
                let model = controller
                Task { @MainActor in
                    guard let coordinator, let map, let model else { return }
                    coordinator.fitToCurrentRoute(map, animated: true)
                    coordinator.observeFitRoute(model, on: map)
                }
            }
        }

        private func observeShowRegion(_ controller: MapController, on mapView: MKMapView) {
            withObservationTracking {
                _ = controller.showRegionRequest
            } onChange: { [weak self, weak mapView, weak controller] in
                let coordinator = self
                let map = mapView
                let model = controller
                Task { @MainActor in
                    guard let coordinator, let map, let model else { return }
                    if let region = model.region {
                        map.setRegion(map.regionThatFits(region), animated: true)
                    }
                    coordinator.observeShowRegion(model, on: map)
                }
            }
        }

        /// Starts observing `locationManager.coordinate` imperatively — the
        /// same technique `observeHighlight`/`observeSheetMetrics` use to keep
        /// continuous updates off SwiftUI's render path entirely. Called from
        /// `update(_:_:)` rather than `makeMapView` (like the others above),
        /// specifically so the first call lands *after* `updateRoute` has set
        /// `routeID` — `centerOnUser` needs an accurate "is a route already
        /// selected" answer on its very first check, not just later ones.
        func observeLocation(_ locationManager: LocationManager, on mapView: MKMapView) {
            guard !isObservingLocation else { return }
            isObservingLocation = true
            trackLocation(locationManager, on: mapView)
        }

        private func trackLocation(_ locationManager: LocationManager, on mapView: MKMapView) {
            centerOnUser(locationManager.coordinate, on: mapView)
            withObservationTracking {
                _ = locationManager.coordinate
            } onChange: { [weak self, weak mapView, weak locationManager] in
                let coordinator = self
                let map = mapView
                let model = locationManager
                Task { @MainActor in
                    guard let coordinator, let map, let model else { return }
                    coordinator.trackLocation(model, on: map)
                }
            }
        }

        /// Centers the map on the user's first fix, once. A route, once
        /// present, owns the viewport — don't also recenter on the user.
        private func centerOnUser(_ coordinate: CLLocationCoordinate2D?, on mapView: MKMapView) {
            guard routeID == nil, let coordinate, !hasCentered else { return }
            hasCentered = true
            RenderSignpost.mark("MapCentered")
            let region = MKCoordinateRegion(
                center: coordinate,
                latitudinalMeters: 2_000,
                longitudinalMeters: 2_000
            )
            mapView.setRegion(region, animated: true)
        }

        /// Rebuilds the highlight annotation so `viewFor` recreates its dot in the
        /// new route tint. Cheap — there is at most one such annotation.
        func refreshHighlightColor(on mapView: MKMapView) {
            guard let annotation = highlightAnnotation else { return }
            mapView.removeAnnotation(annotation)
            mapView.addAnnotation(annotation)
        }

        /// Observes `sheetMetrics.topY` and repositions the tracking button
        /// imperatively, then re-registers. Keeps sheet drags off SwiftUI's
        /// render path — the same technique as `observeHighlight`.
        func observeSheetMetrics(_ metrics: SheetMetrics, on mapView: MKMapView) {
            sheetMetrics = metrics
            applySheetTop(on: mapView)
            withObservationTracking {
                _ = metrics.topY
            } onChange: { [weak self, weak mapView, weak metrics] in
                let coordinator = self
                let map = mapView
                let model = metrics
                Task { @MainActor in
                    guard let coordinator, let map, let model else { return }
                    coordinator.observeSheetMetrics(model, on: map)
                }
            }
        }

        /// The `mapView.bounds.height` last seen by `applySheetTopIfHeightChanged`,
        /// so repeated `update(_:_:)` calls during a sheet drag (where the map's
        /// own bounds haven't moved) can skip reapplying — `observeSheetMetrics`
        /// already keeps the button tracking `topY` at full frame rate on its own.
        private var lastAppliedHeight: CGFloat = -1

        /// Reapplies the button position only when the map's own bounds height
        /// has changed (first layout, rotation) — everything else `topY`-driven
        /// is already handled reactively by `observeSheetMetrics`.
        func applySheetTopIfHeightChanged(on mapView: MKMapView) {
            let height = mapView.bounds.height
            guard height != lastAppliedHeight else { return }
            lastAppliedHeight = height
            applySheetTop(on: mapView)
        }

        /// Positions the "my location" button just above the sheet's top edge,
        /// capped at the vertical midpoint so it never climbs into the top safe area.
        func applySheetTop(on mapView: MKMapView) {
            let height = mapView.bounds.height
            guard height > 0, let constraint = trackingBottomConstraint else { return }
            let spacing: CGFloat = 16
            let reportedTop = sheetMetrics?.topY ?? 0
            // Fall back to a sensible estimate until the sheet reports its position.
            let sheetTop = reportedTop > 0 ? reportedTop : height - 92
            constraint.constant = max(sheetTop, height * 0.5) - spacing
        }

        /// Observes `highlight.coordinate` and applies changes imperatively, then
        /// re-registers. This keeps drag updates entirely off SwiftUI's render path.
        func observeHighlight(_ highlight: RouteHighlight, on mapView: MKMapView) {
            applyHighlight(highlight.coordinate, on: mapView)
            withObservationTracking {
                _ = highlight.coordinate
            } onChange: { [weak self, weak mapView, weak highlight] in
                let coordinator = self
                let map = mapView
                let model = highlight
                Task { @MainActor in
                    guard let coordinator, let map, let model else { return }
                    coordinator.observeHighlight(model, on: map)
                }
            }
        }

        /// Adds/moves/removes the single highlight annotation. O(1).
        private func applyHighlight(_ coordinate: CLLocationCoordinate2D?, on mapView: MKMapView) {
            guard let coordinate else {
                if let annotation = highlightAnnotation {
                    mapView.removeAnnotation(annotation)
                    highlightAnnotation = nil
                }
                return
            }
            if let annotation = highlightAnnotation {
                if annotation.coordinate.latitude != coordinate.latitude
                    || annotation.coordinate.longitude != coordinate.longitude {
                    annotation.coordinate = coordinate
                }
            } else {
                let annotation = MKPointAnnotation()
                annotation.coordinate = coordinate
                highlightAnnotation = annotation
                mapView.addAnnotation(annotation)
            }
            updateHighlightOpacity(on: mapView)
        }

        /// Fades the selection dot when it visually coincides with the "my location"
        /// puck, so the two don't blend into an ambiguous blob and the user's real
        /// position stays the one that reads clearly. zPriority doesn't help here —
        /// MKUserLocationView isn't ordered against custom annotations the normal way.
        private func updateHighlightOpacity(on mapView: MKMapView) {
            guard let annotation = highlightAnnotation,
                  let view = mapView.view(for: annotation) else { return }
            guard let userCoordinate = mapView.userLocation.location?.coordinate else {
                setAlpha(1, on: view)
                return
            }
            let selectionPoint = mapView.convert(annotation.coordinate, toPointTo: mapView)
            let userPoint = mapView.convert(userCoordinate, toPointTo: mapView)
            let distance = hypot(selectionPoint.x - userPoint.x, selectionPoint.y - userPoint.y)
            setAlpha(distance < Self.overlapThresholdPoints ? 0.25 : 1, on: view)
        }

        private func setAlpha(_ alpha: CGFloat, on view: MKAnnotationView) {
            #if os(macOS)
            view.alphaValue = alpha
            #else
            view.alpha = alpha
            #endif
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard !(annotation is MKUserLocation) else { return nil }

            let identifier = "routeHighlight"
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier)
                ?? MKAnnotationView(annotation: annotation, reuseIdentifier: identifier)
            view.annotation = annotation
            view.canShowCallout = false

            // A small filled dot in the route tint with a white ring.
            let diameter: CGFloat = 18
            view.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
            #if os(macOS)
            view.wantsLayer = true
            let layer = view.layer ?? CALayer()
            view.layer = layer
            layer.backgroundColor = NSColor(routeTint).withAlphaComponent(1).cgColor
            layer.borderColor = NSColor.white.cgColor
            #else
            let layer = view.layer
            layer.backgroundColor = UIColor(routeTint).withAlphaComponent(1).cgColor
            layer.borderColor = UIColor.white.cgColor
            #endif
            layer.cornerRadius = diameter / 2
            layer.borderWidth = 3
            layer.shadowColor = CGColor(gray: 0, alpha: 1)
            layer.shadowOpacity = 0.3
            layer.shadowRadius = 2
            layer.shadowOffset = .zero
            return view
        }

        func mapView(_ mapView: MKMapView, didUpdate userLocation: MKUserLocation) {
            updateHighlightOpacity(on: mapView)
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            // Zooming changes the on-screen distance between two fixed coordinates,
            // so the overlap fade needs to be re-checked, not just on move/relocate.
            updateHighlightOpacity(on: mapView)
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tileOverlay = overlay as? TileOverlay {
                return CachingTileOverlayRenderer(overlay: tileOverlay)
            }
            if let polyline = overlay as? MKPolyline {
                let renderer = DirectionalPolylineRenderer(polyline: polyline)
                applyStyle(to: renderer)
                renderer.lineJoin = .round
                renderer.lineCap = .round
                routeRenderer = renderer
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }
    }
}
