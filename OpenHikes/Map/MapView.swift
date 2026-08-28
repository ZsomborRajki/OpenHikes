//
//  MapView.swift
//  OpenHikes
//
//  A full-screen MKMapView that renders raster tiles from the selected
//  provider — or, when the selection is the system base map, MapKit's own
//  cartography with no overlay at all — and shows the user's location.
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

    /// The `tileSourceKey` standing for "no overlay". A sentinel rather than
    /// `nil` so the coordinator can tell "the system base map is installed"
    /// apart from "nothing has been applied yet", which is what stops the very
    /// first update pass from removing an overlay it never added.
    private static let systemBaseMapKey = "system-base-map"

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

    /// The selected tile source (provider + resolved template), or `nil` when
    /// the selected map draws no raster tiles and MapKit's own base map is left
    /// in place. Changing it rebuilds (or removes) the overlay on the next update.
    var tileSource: ActiveTileSource?

    /// Observed directly by the map so the detail view's Zoom button can re-fit
    /// the route without re-rendering any view.
    var mapController: MapController

    /// Whether a photo can be taken right now, and the two requests the camera
    /// pill raises. Observed directly by the map (not via SwiftUI) so pushing
    /// or popping a screen that can receive a photo shows or hides the pill
    /// without an update pass — see ``MapPhotoControlsView``.
    var photoCapture: PhotoCaptureController

    /// Where the open hike's photos were taken. Observed directly by the map
    /// (not via SwiftUI) so taking, importing or deleting one redraws MapKit's
    /// annotations rather than this view — see ``PhotoMapPinController``.
    var photoPins: PhotoMapPinController

    /// Whether the weather badge is currently drawn over the map.
    ///
    /// The badge is a SwiftUI overlay in the root view's body and this map
    /// cannot see it, but the credit line hangs off its bottom edge — so when
    /// there is no forecast to show, the line takes the badge's own slot
    /// instead of leaving a gap where it would have been. See
    /// ``attributionTop(in:belowWeatherBadge:)``.
    ///
    /// This costs the root body nothing it was not already paying: the overlay
    /// closure is inlined into that body and already reads the same forecast,
    /// so the dependency exists whether or not it is passed down here.
    var showsWeatherBadge: Bool

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
            && lhs.photoPins === rhs.photoPins
            && lhs.showsWeatherBadge == rhs.showsWeatherBadge
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
        coordinator.observePhotoPins(photoPins, on: mapView)

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

    /// Rebuilds the tile overlay when the selected provider changes, and removes
    /// it entirely when the selection is the system base map. No-op while the
    /// same source is already installed, so unrelated updates don't churn it.
    private func applyTileSource(to mapView: MKMapView, _ coordinator: Coordinator) {
        let key = tileSource.map { source in
            "\(source.providerID)|\(source.urlTemplate)|\(source.maximumZ)"
        } ?? Self.systemBaseMapKey
        guard coordinator.tileSourceKey != key else { return }
        coordinator.tileSourceKey = key
        RenderSignpost.mark("MapTileSourceRebuilt", key)

        // Before the early return below: the system base map is a change of
        // credit too — MapKit draws its own **Legal** link, so ours has to go
        // away rather than keep crediting a provider that is no longer drawn.
        //
        // No repositioning to do afterwards: the credit line is pinned to the
        // top of the map and takes no part in the row the sheet drives.
        #if os(iOS)
        coordinator.attributionView?.update(with: tileSource?.attribution)
        #endif

        if let existing = coordinator.tileOverlay {
            mapView.removeOverlay(existing)
            coordinator.tileOverlay = nil
        }

        // No overlay at all, rather than an empty one: `canReplaceMapContent`
        // is what hides Apple's base map, so simply leaving it off is what
        // shows it — and with nothing installed, no tile is ever requested,
        // fetched, decoded, cached or auto-saved. That is the whole of the
        // saving this option exists for.
        guard let tileSource else {
            #if DEBUG
            Self.logger.debug("Removed tile overlay; drawing the system base map")
            #endif
            return
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
        addAttribution(to: mapView, coordinator, alignedTo: guide)
        // Replaces the placeholders above with real positions as soon as the
        // map has a height to measure against.
        coordinator.applySheetTop(on: mapView)
        #endif
    }

    #if os(iOS)
    /// The credit line, hung directly beneath the weather badge on the leading
    /// edge and left-aligned with it. It stays on the map rather than moving
    /// into the sheet, as the providers' terms require. See
    /// ``MapAttributionView``.
    ///
    /// It does not move. The tracking button and the camera pill ride the
    /// sheet because they are controls the sheet would otherwise cover; this
    /// is a legal notice, and one that slides around under every drag is
    /// harder to read and harder to hit than one that stays put. Pinning it to
    /// the top takes it out of ``MapView/Coordinator/applySheetTop(on:)``
    /// altogether, so a drag now moves two views rather than three.
    ///
    /// Below the badge rather than beside it, which is what keeps it clear of
    /// everything else up there in one stroke: MapKit draws its compass and
    /// its scale bar in the strip above, and this sits under both. The badge
    /// itself cannot be anchored against — it is a SwiftUI overlay in a
    /// different hierarchy, not a subview of this map — so the two agree by
    /// sharing ``WeatherBadge``'s own geometry instead; see
    /// ``attributionTop(in:belowWeatherBadge:)``.
    ///
    /// The badge is conditional and the slot is not. Without a forecast there
    /// is nothing above the line to hang it from, so it moves up and takes the
    /// badge's own position; when one arrives it drops below it. That is the
    /// only thing that moves this view — it takes no part in the sheet's drag.
    private func addAttribution(
        to mapView: MKMapView,
        _ coordinator: Coordinator,
        alignedTo guide: UILayoutGuide
    ) {
        let attribution = MapAttributionView()
        attribution.translatesAutoresizingMaskIntoConstraints = false
        mapView.addSubview(attribution)
        coordinator.attributionView = attribution
        coordinator.showsWeatherBadge = showsWeatherBadge

        // Against the map's own top edge, because that is what the badge's
        // padding is measured from — the map ignores the safe area. Re-applied
        // when the forecast comes or goes, and on a text-size change, which is
        // the only other thing that moves the badge's bottom.
        let top = attribution.topAnchor.constraint(
            equalTo: mapView.topAnchor,
            constant: Self.attributionTop(in: mapView, belowWeatherBadge: showsWeatherBadge)
        )
        coordinator.attributionTopConstraint = top

        NSLayoutConstraint.activate([
            top,
            // The safe area rather than the map's edge, which are the same
            // thing in portrait — where this lines up with the badge exactly —
            // and are not in landscape, where the map's edge is under the
            // notch. A credit the reader cannot see is not a credit.
            attribution.leadingAnchor.constraint(
                equalTo: guide.leadingAnchor,
                constant: WeatherBadge.leadingPadding
            ),
            // A ceiling rather than a width: the line is as wide as its
            // credits need and no wider, but a provider that names three
            // parties must wrap inside the map rather than run off it.
            attribution.trailingAnchor.constraint(
                lessThanOrEqualTo: guide.trailingAnchor,
                constant: -Self.controlInset
            ),
        ])
        coordinator.trackContentSizeCategory(on: mapView)
        attribution.update(with: tileSource?.attribution)
    }
    #endif

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

    #if os(iOS)
    /// How far below the map's top edge the credit line is pinned.
    ///
    /// Two slots, not one. With a forecast on screen the line clears the
    /// badge's bottom, using the same gap as the rest of this chrome; without
    /// one it moves up into the slot the badge would have occupied, rather
    /// than hanging under a space where nothing is drawn.
    ///
    /// Recomputed rather than stored because the badge's height is not fixed;
    /// see ``weatherBadgeHeight(in:)``.
    static func attributionTop(in mapView: MKMapView, belowWeatherBadge: Bool) -> CGFloat {
        guard belowWeatherBadge else { return WeatherBadge.topPadding }
        return WeatherBadge.topPadding + weatherBadgeHeight(in: mapView) + controlInset
    }

    /// How tall the weather badge draws at the reader's current text size.
    ///
    /// Computed rather than measured because the badge is a SwiftUI overlay
    /// *over* this map rather than a subview *of* it — there is no view here
    /// to ask. What there is instead is the badge's own geometry, which it
    /// exposes for exactly this; the arithmetic below is its body's.
    ///
    /// The floor is real and is what applies at the default text size: the
    /// capsule is a little under the standard control size, and
    /// `.minimumTapTarget()` grows the button around it to meet that.
    private static func weatherBadgeHeight(in mapView: MKMapView) -> CGFloat {
        let capsule = UIFont.preferredFont(
            forTextStyle: WeatherBadge.heightDrivingUITextStyle,
            compatibleWith: mapView.traitCollection
        ).lineHeight + WeatherBadge.verticalPadding * 2
        return max(MapPhotoControlsView.controlSize, capsule)
    }
    #endif

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
        #if os(iOS)
        // Cheap and idempotent — it writes only when the line's slot has
        // actually moved, which a forecast arriving, a rotation or a text-size
        // change can each do.
        coordinator.showsWeatherBadge = showsWeatherBadge
        coordinator.applyAttributionClearance(on: mapView)
        #endif
    }

    #if os(macOS)
    func makeNSView(context: Context) -> MKMapView { makeMapView(context.coordinator) }
    func updateNSView(_ mapView: MKMapView, context: Context) { update(mapView, context.coordinator) }
    #else
    func makeUIView(context: Context) -> MKMapView { makeMapView(context.coordinator) }
    func updateUIView(_ mapView: MKMapView, context: Context) { update(mapView, context.coordinator) }
    #endif

}
