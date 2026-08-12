//
//  MapView.swift
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

struct MapView: MapViewRepresentable, Equatable {
    fileprivate static let logger = Logger(subsystem: "OpenTrails", category: "MapView")

    /// Source of the user's live location. Observed directly by the map (not
    /// via SwiftUI), the same technique `highlight`/`sheetMetrics` use, so the
    /// ~1/sec publish that drives it (continuous whether or not the user is
    /// moving — see `LocationManager`) never re-renders any view. The map
    /// centers on the user's first fix, once, while no route is selected —
    /// see `Coordinator.observeLocation`.
    var locationManager: LocationManager

    /// An imported/selected route to draw and zoom to. Draws a line and fits the map to it.
    /// Geometry only — how it is drawn comes from `routeStyle` below.
    var route: DisplayedRoute?

    /// The drawn route's tint and width. Observed directly by the map (not via
    /// SwiftUI) so a colour or width drag restyles the existing polyline
    /// renderer without re-rendering any view — see ``RouteStyle``.
    var routeStyle: RouteStyle

    /// Observed directly by the map (not via SwiftUI) so scrubbing the elevation
    /// chart moves the marker without re-rendering any view.
    var highlight: RouteHighlight

    /// The growing recorded track. Its revision is observed directly by the
    /// coordinator so accepted fixes update only MapKit overlays.
    var recordingTrace: RecordingTrace

    /// Observed directly by the map (not via SwiftUI) so dragging the sheet
    /// repositions the "my location" button without re-rendering any view.
    var sheetMetrics: SheetMetrics

    /// The selected tile source (provider + resolved template). Changing it
    /// rebuilds the overlay on the next update.
    var tileSource: ActiveTileSource

    /// Observed directly by the map so the detail view's Zoom button can re-fit
    /// the route without re-rendering any view.
    var mapController: MapController

    /// Lets `.equatable()` skip `updateUIView` when nothing actually changed —
    /// without it, SwiftUI calls `updateUIView` on every ancestor body pass
    /// that touches this view's transaction (e.g. the sheet's per-frame drag
    /// updates), even though `routeStyle`/`highlight`/`sheetMetrics`/
    /// `mapController`/`locationManager` are deliberately observed outside
    /// SwiftUI for exactly that scenario. Those controller models are reference types the
    /// parent always hands down as the same instance, so identity comparison is
    /// correct: their *contents* changing on their own is not a reason to
    /// re-run `updateUIView`.
    static func == (lhs: MapView, rhs: MapView) -> Bool {
        lhs.route == rhs.route
            && lhs.routeStyle === rhs.routeStyle
            && lhs.highlight === rhs.highlight
            && lhs.recordingTrace === rhs.recordingTrace
            && lhs.sheetMetrics === rhs.sheetMetrics
            && lhs.tileSource == rhs.tileSource
            && lhs.mapController === rhs.mapController
            && lhs.locationManager === rhs.locationManager
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Internal rather than private so `MapCoordinatorTests` can drive the two
    /// entry points SwiftUI drives — building the map and updating it — against
    /// a real `MKMapView`. Everything below them stays private.
    func makeMapView(_ coordinator: Coordinator) -> MKMapView {
        // Fires once per MKMapView creation — if this repeats, something is
        // destroying the representable's identity (e.g. an `.id()` upstream
        // churning), which throws away all MapKit state, not just SwiftUI's.
        RenderSignpost.mark("MapViewCreated")
        let mapView = MKMapView()
        mapView.delegate = coordinator
        mapView.showsUserLocation = true
        mapView.pointOfInterestFilter = .includingAll
        coordinator.observeHighlight(highlight, on: mapView)
        coordinator.observeRecordingTrace(recordingTrace, on: mapView)
        coordinator.observeSheetMetrics(sheetMetrics, on: mapView)
        coordinator.observeMapController(mapController, on: mapView)
        coordinator.observeRouteStyle(routeStyle, on: mapView)

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
        RenderSignpost.mark("MapTileSourceRebuilt", key)

        if let existing = coordinator.tileOverlay {
            mapView.removeOverlay(existing)
        }

        let overlay = TileOverlay(providerID: tileSource.providerID, urlTemplate: tileSource.urlTemplate)
        // The two below are `MKTileOverlay`'s own properties, so they stay
        // assignments; like `providerID` they're set before the overlay is
        // handed to MapKit, and never touched again afterwards.
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

    /// Draws the current route (if any) and fits the map to it. No-op while the
    /// same route is already shown, so unrelated view updates don't re-zoom.
    private func updateRoute(_ mapView: MKMapView, _ coordinator: Coordinator) {
        guard coordinator.routeID != route?.id else { return }
        coordinator.routeID = route?.id
        RenderSignpost.mark("MapRouteRebuilt")

        if let existing = coordinator.routeOverlay {
            mapView.removeOverlay(existing)
            coordinator.routeOverlay = nil
        }

        guard let route, route.coordinates.count > 1 else { return }

        // The line's colour and width aren't read here: `observeRouteStyle`
        // keeps `coordinator.routeTint`/`routeWidth` current, and `rendererFor`
        // takes the new polyline's style from those.
        let polyline = MKPolyline(coordinates: route.coordinates, count: route.coordinates.count)
        coordinator.routeOverlay = polyline
        if let tileOverlay = coordinator.tileOverlay {
            mapView.insertOverlay(polyline, above: tileOverlay)
        } else {
            mapView.addOverlay(polyline, level: .aboveLabels)
        }

        coordinator.fitToCurrentRoute(mapView, animated: true)
    }

    func update(_ mapView: MKMapView, _ coordinator: Coordinator) {
        // Fires on every SwiftUI-driven update pass, whether or not any of the
        // steps below actually change anything — compare its rate against the
        // "Rebuilt"/"Centered"/"Restyled" marks to see how much of that is
        // real work vs. free no-ops.
        RenderSignpost.mark("MapUpdateCalled")
        applyTileSource(to: mapView, coordinator)
        updateRoute(mapView, coordinator)
        // Restyling the line is deliberately absent: `observeRouteStyle` applies
        // tint and width straight from `routeStyle`, so a colour or width drag
        // never has to reach this method — which only runs when SwiftUI
        // re-renders, and that is the cost the arrangement exists to avoid.
        //
        // Idempotent — only the first call (after `updateRoute` above has set
        // `routeID`) actually starts the location tracking; see
        // `Coordinator.observeLocation`.
        coordinator.observeLocation(locationManager, on: mapView)
        // Only reapplies when the map's own bounds height moved (first layout,
        // rotation) — `sheetMetrics.topY` changes are already tracked at full
        // frame rate by `observeSheetMetrics`'s own observation, so redoing it
        // here unconditionally would just repeat that work on every one of
        // this method's (frequent, often no-op) calls.
        coordinator.applySheetTopIfHeightChanged(on: mapView)
    }

    #if os(macOS)
    func makeNSView(context: Context) -> MKMapView { makeMapView(context.coordinator) }
    func updateNSView(_ mapView: MKMapView, context: Context) { update(mapView, context.coordinator) }
    #else
    func makeUIView(context: Context) -> MKMapView { makeMapView(context.coordinator) }
    func updateUIView(_ mapView: MKMapView, context: Context) { update(mapView, context.coordinator) }
    #endif

}
