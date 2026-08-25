//
//  MapView.swift
//  OpenHikes
//
//  A full-screen MKMapView that renders raster tiles from the selected
//  provider and shows the user's location.
//

import MapKit
import os
import SwiftUI

#if os(macOS)
typealias MapViewRepresentable = NSViewRepresentable
#else
typealias MapViewRepresentable = UIViewRepresentable
#endif

struct MapView: MapViewRepresentable, Equatable {
    private static let logger = Logger(subsystem: "OpenHikes", category: "MapView")

    /// Source of the user's live location. Observed directly by the map (not
    /// via SwiftUI), the same technique `highlight`/`sheetMetrics` use, so the
    /// publishes that drive it (at most one a second, and none at all while
    /// the user stands still — see `LocationManager`) never re-render any
    /// view. The map centers on the user's first fix, once, while no route is
    /// selected — see `Coordinator.observeLocation`.
    var locationManager: LocationManager

    /// An imported/selected route to draw and zoom to. Draws a line and fits the map to it.
    /// Geometry only — how it is drawn comes from `routeStyle` below.
    var route: DisplayedRoute?

    /// The drawn route's tint, width and line pattern. Observed directly by the
    /// map (not via SwiftUI) so a colour, width or pattern change restyles the
    /// existing polyline renderer without re-rendering any view — see
    /// ``RouteStyle``.
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

    /// Whether a photo can be taken right now, and the two requests the camera
    /// pill raises. Observed directly by the map (not via SwiftUI) so pushing
    /// or popping a screen that can receive a photo shows or hides the pill
    /// without an update pass — see ``MapPhotoControlsView``.
    var photoCapture: PhotoCaptureController

    /// Lets `.equatable()` skip `updateUIView` when nothing actually changed —
    /// without it, SwiftUI calls `updateUIView` on every ancestor body pass
    /// that touches this view's transaction (e.g. the sheet's per-frame drag
    /// updates), even though `routeStyle`/`highlight`/`sheetMetrics`/
    /// `mapController`/`locationManager` are deliberately observed outside
    /// SwiftUI for exactly that scenario. Those controller models are reference types the
    /// parent always hands down as the same instance, so identity comparison is
    /// correct: their *contents* changing on their own is not a reason to
    /// re-run `updateUIView`.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.route == rhs.route
            && lhs.routeStyle === rhs.routeStyle
            && lhs.highlight === rhs.highlight
            && lhs.recordingTrace === rhs.recordingTrace
            && lhs.sheetMetrics === rhs.sheetMetrics
            && lhs.tileSource == rhs.tileSource
            && lhs.mapController === rhs.mapController
            && lhs.locationManager === rhs.locationManager
            && lhs.photoCapture === rhs.photoCapture
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
        // The launch is over when there is a map, not when there is a frame.
        // `histogrammedTimeToFirstDraw` stops at the first CA commit, which on
        // this app is a sheet over an empty map — see `LaunchMeasurement`.
        LaunchMeasurement.finish()
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

        // After `addControls`, deliberately: the pill's first visibility pass
        // needs the view to exist, or a screen that is already offering one
        // when the map is built (a restored selection, a widget deep link)
        // leaves it hidden until the *next* availability change.
        coordinator.observePhotoControls(photoCapture)

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
    /// the "my location" button has no flag on iOS, so it's added as a subview —
    /// and so is the camera pill facing it across the map.
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
        coordinator.trackingButton = tracking

        let initialTrackingButtonY: CGFloat = 400
        // The bottom is pinned to the map's top (full-screen space) so its constant
        // is a global Y that the sheet observation drives as the sheet is dragged.
        let bottom = tracking.bottomAnchor.constraint(equalTo: mapView.topAnchor, constant: initialTrackingButtonY)
        coordinator.trackingBottomConstraint = bottom

        let guide = mapView.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            tracking.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -Self.controlInset),
            bottom,
        ])

        addPhotoControls(to: mapView, coordinator, alignedTo: guide)
        // Replaces the placeholders above with real positions as soon as the
        // map has a height to measure against.
        coordinator.applySheetTop(on: mapView)
        #endif
    }

    #if os(iOS)
    /// The camera pill, on the leading edge opposite the tracking button and
    /// bottom-pinned to the same driven Y, so the two stay level through every
    /// sheet drag without either of them re-rendering.
    private func addPhotoControls(
        to mapView: MKMapView,
        _ coordinator: Coordinator,
        alignedTo guide: UILayoutGuide
    ) {
        let controls = MapPhotoControlsView(
            onCamera: { [photoCapture] in photoCapture.requestCamera() },
            onLibrary: { [photoCapture] in photoCapture.requestLibrary() }
        )
        controls.translatesAutoresizingMaskIntoConstraints = false
        // Starts out of the way: `observePhotoControls` decides on the first
        // pass whether there is anything to photograph, and a pill that
        // flashed in before it answered would be visible on the search screen.
        controls.isHidden = true
        controls.alpha = 0
        mapView.addSubview(controls)
        coordinator.photoControls = controls

        let initialPhotoControlsY: CGFloat = 400
        let bottom = controls.bottomAnchor.constraint(
            equalTo: mapView.topAnchor,
            constant: initialPhotoControlsY
        )
        coordinator.photoControlsBottomConstraint = bottom

        NSLayoutConstraint.activate([
            controls.leadingAnchor.constraint(
                equalTo: guide.leadingAnchor,
                constant: Self.controlInset
            ),
            bottom,
        ])
    }
    #endif

    /// How far the map's floating controls sit in from its safe area.
    private static let controlInset: CGFloat = 12

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
        if !coordinator.inferredRouteOverlays.isEmpty {
            mapView.removeOverlays(coordinator.inferredRouteOverlays)
            coordinator.inferredRouteOverlays = []
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
        addInferredOverlays(route, on: mapView, coordinator, above: polyline)

        coordinator.fitToCurrentRoute(mapView, animated: true)
    }

    /// Overlays the stretches that were inferred rather than measured, on top
    /// of the solid line they belong to.
    ///
    /// Drawn over rather than instead of the route: the solid line stays
    /// continuous underneath, so the dashes read as a qualification of the
    /// route rather than as a hole in it, and nothing has to be spliced out of
    /// the geometry the rest of the map is fitted and scrubbed against.
    private func addInferredOverlays(
        _ route: DisplayedRoute,
        on mapView: MKMapView,
        _ coordinator: Coordinator,
        above base: MKPolyline
    ) {
        guard !route.inferredSegments.isEmpty else { return }
        let overlays = route.inferredSegments.map { segment in
            MKPolyline(coordinates: segment, count: segment.count)
        }
        coordinator.inferredRouteOverlays = overlays
        for overlay in overlays {
            mapView.insertOverlay(overlay, above: base)
        }
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
