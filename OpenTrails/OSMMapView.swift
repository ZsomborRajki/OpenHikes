//
//  OSMMapView.swift
//  OpenTrails
//
//  A full-screen MKMapView that renders OpenStreetMap tiles and follows the user.
//

import SwiftUI
import MapKit
import os

#if os(macOS)
typealias MapViewRepresentable = NSViewRepresentable
#else
typealias MapViewRepresentable = UIViewRepresentable
#endif

/// A route to draw on the map, keyed by `id` so the map only redraws when it changes.
struct DisplayedRoute {
    let id: UUID
    let coordinates: [CLLocationCoordinate2D]
    /// Line color, including the user's chosen alpha.
    var tint: Color = .green
    /// Line width in points.
    var width: Double = 5
}

/// The scrub-highlight location, held in a reference type so it can be updated at
/// drag frequency *without* re-rendering any SwiftUI view. The map observes it
/// directly and moves a single annotation.
@MainActor
@Observable
final class RouteHighlight {
    var coordinate: CLLocationCoordinate2D?
}

/// The sheet's live top edge (global Y), held in a reference type so the sheet can
/// update it at drag frequency *without* re-rendering any SwiftUI view. The map
/// observes it directly and repositions the "my location" button.
@MainActor
@Observable
final class SheetMetrics {
    var topY: CGFloat = 0
}

/// One-shot map commands the detail view issues (e.g. the Zoom button). Held in a
/// reference type the map observes directly, so triggering one doesn't re-render
/// any SwiftUI view. `fitRouteRequest` is a token — bumping it asks the map to
/// re-fit the current route into view.
@MainActor
@Observable
final class MapController {
    private(set) var fitRouteRequest: Int = 0
    private(set) var showRegionRequest: Int = 0
    private(set) var region: MKCoordinateRegion?

    /// Ask the map to zoom to fit the currently drawn route.
    func fitToRoute() { fitRouteRequest += 1 }

    /// Ask the map to zoom to a region (e.g. a search result).
    func show(_ region: MKCoordinateRegion) {
        self.region = region
        showRegionRequest += 1
    }
}

struct OSMMapView: MapViewRepresentable {
    fileprivate static let logger = Logger(subsystem: "OpenTrails", category: "MapView")

    /// The coordinate to center on. The map recenters the first time this is set.
    var coordinate: CLLocationCoordinate2D?

    /// An imported/selected route to draw and zoom to. Draws a line and fits the map to it.
    var route: DisplayedRoute?

    /// Observed directly by the map (not via SwiftUI) so scrubbing the elevation
    /// chart moves the marker without re-rendering any view.
    var highlight: RouteHighlight

    /// Observed directly by the map (not via SwiftUI) so dragging the sheet
    /// repositions the "my location" button without re-rendering any view.
    var sheetMetrics: SheetMetrics

    /// The selected tile source (provider + resolved template). Changing it
    /// rebuilds the overlay on the next update.
    var tileSource: ActiveTileSource

    /// Observed directly by the map so the detail view's Zoom button can re-fit
    /// the route without re-rendering any view.
    var mapController: MapController

    func makeCoordinator() -> Coordinator { Coordinator() }

    private func makeMapView(_ coordinator: Coordinator) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = coordinator
        mapView.showsUserLocation = true
        mapView.pointOfInterestFilter = .excludingAll
        coordinator.observeHighlight(highlight, on: mapView)
        coordinator.observeSheetMetrics(sheetMetrics, on: mapView)
        coordinator.observeMapController(mapController, on: mapView)

        // Raster tiles from the selected provider, replacing Apple's base map.
        applyTileSource(to: mapView, coordinator)

        addControls(to: mapView, coordinator)

        return mapView
    }

    /// Rebuilds the tile overlay when the selected provider changes. No-op while
    /// the same source is already installed, so unrelated updates don't churn it.
    private func applyTileSource(to mapView: MKMapView, _ coordinator: Coordinator) {
        let key = "\(tileSource.providerID)|\(tileSource.urlTemplate)|\(tileSource.maximumZ)"
        guard coordinator.tileSourceKey != key else { return }
        coordinator.tileSourceKey = key

        if let existing = coordinator.tileOverlay {
            mapView.removeOverlay(existing)
        }

        let overlay = OSMTileOverlay(urlTemplate: tileSource.urlTemplate)
        overlay.providerID = tileSource.providerID
        overlay.canReplaceMapContent = true
        overlay.maximumZ = tileSource.maximumZ
        // Below the route line, which is also added at `.aboveLabels`.
        mapView.insertOverlay(overlay, at: 0, level: .aboveLabels)
        coordinator.tileOverlay = overlay
        #if DEBUG
        Self.logger.debug("Installed tile overlay for \(key, privacy: .public)")
        #endif
    }

    /// Enables MapKit's standard controls. Compass and scale are built-in flags;
    /// the "my location" button has no flag on iOS, so it's added as a subview.
    private func addControls(to mapView: MKMapView, _ coordinator: Coordinator) {
        mapView.showsCompass = true
        mapView.showsScale = true

        #if os(macOS)
        mapView.showsZoomControls = true
        mapView.showsPitchControl = true
        #elseif os(iOS)
        let tracking = MKUserTrackingButton(mapView: mapView)
        tracking.translatesAutoresizingMaskIntoConstraints = false
        mapView.addSubview(tracking)

        // The bottom is pinned to the map's top (full-screen space) so its constant
        // is a global Y that the sheet observation drives as the sheet is dragged.
        let bottom = tracking.bottomAnchor.constraint(equalTo: mapView.topAnchor, constant: 400)
        coordinator.trackingBottomConstraint = bottom

        let guide = mapView.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            tracking.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -12),
            bottom,
        ])
        #endif
    }

    private func centerIfNeeded(_ mapView: MKMapView, _ coordinator: Coordinator) {
        // A route, once present, owns the viewport — don't also recenter on the user.
        guard route == nil, let coordinate, !coordinator.hasCentered else { return }
        coordinator.hasCentered = true
        let region = MKCoordinateRegion(
            center: coordinate,
            latitudinalMeters: 2_000,
            longitudinalMeters: 2_000
        )
        mapView.setRegion(region, animated: true)
    }

    /// Draws the current route (if any) and fits the map to it. No-op while the
    /// same route is already shown, so unrelated view updates don't re-zoom.
    private func updateRoute(_ mapView: MKMapView, _ coordinator: Coordinator) {
        guard coordinator.routeID != route?.id else { return }
        coordinator.routeID = route?.id

        if let existing = coordinator.routeOverlay {
            mapView.removeOverlay(existing)
            coordinator.routeOverlay = nil
        }

        guard let route, route.coordinates.count > 1 else { return }

        coordinator.routeTint = route.tint
        coordinator.routeWidth = route.width
        let polyline = MKPolyline(coordinates: route.coordinates, count: route.coordinates.count)
        coordinator.routeOverlay = polyline
        mapView.addOverlay(polyline, level: .aboveLabels)

        coordinator.fitToCurrentRoute(mapView, animated: true)
    }

    /// Restyles the drawn route (color/alpha, width, and the highlight dot) when
    /// those change without rebuilding the overlay — the route id stays the same.
    private func updateRouteStyle(_ mapView: MKMapView, _ coordinator: Coordinator) {
        guard let route, coordinator.routeOverlay != nil else { return }
        let tintChanged = coordinator.routeTint != route.tint
        let widthChanged = coordinator.routeWidth != route.width
        guard tintChanged || widthChanged else { return }
        coordinator.routeTint = route.tint
        coordinator.routeWidth = route.width
        if let renderer = coordinator.routeRenderer {
            coordinator.applyStyle(to: renderer)
            renderer.setNeedsDisplay()
        }
        // The dot mirrors the tint (opaque); only refresh it when the color moves.
        if tintChanged { coordinator.refreshHighlightColor(on: mapView) }
    }

    private func update(_ mapView: MKMapView, _ coordinator: Coordinator) {
        applyTileSource(to: mapView, coordinator)
        centerIfNeeded(mapView, coordinator)
        updateRoute(mapView, coordinator)
        updateRouteStyle(mapView, coordinator)
        // Reapply on layout-driven updates (e.g. first layout, rotation) so the
        // button is positioned correctly even before the sheet reports a drag.
        coordinator.applySheetTop(on: mapView)
    }

    #if os(macOS)
    func makeNSView(context: Context) -> MKMapView { makeMapView(context.coordinator) }
    func updateNSView(_ mapView: MKMapView, context: Context) { update(mapView, context.coordinator) }
    #else
    func makeUIView(context: Context) -> MKMapView { makeMapView(context.coordinator) }
    func updateUIView(_ mapView: MKMapView, context: Context) { update(mapView, context.coordinator) }
    #endif

    final class Coordinator: NSObject, MKMapViewDelegate {
        var hasCentered = false
        var routeID: UUID?
        var routeOverlay: MKPolyline?
        /// The live renderer for the route line, kept so a tint change can recolor
        /// it in place without rebuilding the overlay.
        weak var routeRenderer: MKPolylineRenderer?
        /// The currently installed tile overlay and a key identifying its source.
        var tileOverlay: OSMTileOverlay?
        var tileSourceKey: String?
        var routeTint: Color = .green
        var routeWidth: Double = 5
        var highlightAnnotation: MKPointAnnotation?
        var trackingBottomConstraint: NSLayoutConstraint?
        private weak var sheetMetrics: SheetMetrics?

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

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let osmOverlay = overlay as? OSMTileOverlay {
                return CachingTileOverlayRenderer(overlay: osmOverlay)
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
