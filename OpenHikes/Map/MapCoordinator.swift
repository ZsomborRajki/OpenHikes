//
//  MapCoordinator.swift
//  OpenHikes
//
//  MapView's MKMapViewDelegate: owns the map's overlays/annotations and
//  applies RouteHighlight/SheetMetrics/MapController/LocationManager changes
//  imperatively, keeping continuous updates entirely off SwiftUI's render path.
//

import MapKit
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

extension MapView {
    final class Coordinator: NSObject, MKMapViewDelegate {
        /// Whether the user's first fix has been dealt with — either by
        /// centring the map on it, or by deliberately leaving the viewport to
        /// a selected route. Recorded either way, so a later deselection
        /// doesn't hand the next fix a recentre the user never asked for.
        var hasHandledFirstFix = false
        /// Guards `observeLocation` so `update(_:_:)` — called on every
        /// SwiftUI-driven pass — only starts the location-tracking loop once.
        private var isObservingLocation = false
        var routeID: UUID?
        var routeOverlay: MKPolyline?
        /// The stretches of the drawn route that were inferred rather than
        /// measured. Separate overlays because MapKit styles a polyline as a
        /// whole, and this is the one part of the line that has to be drawn
        /// differently from the rest of it — see ``RouteProvenance``.
        var inferredRouteOverlays: [MKPolyline] = []
        /// The stretches of the drawn route the recording was paused across.
        /// Separate overlays for the same reason the inferred ones are, and
        /// styled differently from them because they say a different thing —
        /// see ``RouteBoundary``.
        var pausedRouteOverlays: [MKPolyline] = []
        /// The stretches of the drawn route a finished walk covered, drawn
        /// twice — a casing and a line — so they stand out from the route
        /// they sit on. See `MapCoordinator+WalkHighlight.swift`.
        var walkHighlightCasingOverlays: [MKPolyline] = []
        var walkHighlightOverlays: [MKPolyline] = []
        var recordingChunkOverlays: [MKPolyline] = []
        var recordingTailOverlay: MKPolyline?
        var recordingReviewOverlay: MKPolyline?
        private var recordingTraceGeneration = -1
        /// What the drawn overlays currently correspond to. `nil` means nothing
        /// is drawn, which is not the same as "drawn at revision 0".
        private var appliedTailRevision: Int?
        private var appliedReviewRevision: Int?
        /// Whether the app is in the foreground.
        ///
        /// The recording trace is the one thing here that changes at GPS
        /// frequency, and a backgrounded app draws to nobody: an `MKPolyline`
        /// allocation and a MapKit overlay swap per fix, for every fix of a
        /// six-hour walk, produce output no one ever sees. Applying the trace
        /// is therefore deferred while backgrounded and caught up in one pass
        /// on return — the trace itself keeps accumulating, so nothing is
        /// lost, only not drawn. Observed through notifications rather than
        /// `scenePhase` so this stays entirely off SwiftUI's render path,
        /// which is the whole point of the coordinator.
        private var isForeground = true
        private var pendingRecordingTrace = false
        private weak var observedRecordingTrace: RecordingTrace?
        private weak var observedRecordingMapView: MKMapView?
        /// `nonisolated(unsafe)` for the same reason ``PowerStateMonitor``'s
        /// tokens are: `deinit` is nonisolated and cannot touch main-actor
        /// state. Registration reads and writes this on the main actor, and
        /// `deinit` reads it only once the last reference is gone, so the two
        /// can never overlap.
        nonisolated(unsafe) private var scenePhaseObservers: [NSObjectProtocol] = []

        deinit {
            for observer in scenePhaseObservers {
                NotificationCenter.default.removeObserver(observer)
            }
        }
        /// The live renderer for the route line, kept so a tint change can recolor
        /// it in place without rebuilding the overlay.
        weak var routeRenderer: MKPolylineRenderer?
        /// The currently installed tile overlay and a key identifying its source.
        var tileOverlay: TileOverlay?
        var tileSourceKey: String?
        /// The style the line is currently drawn in. Seeded and then kept
        /// current by `observeRouteStyle`, so it is what `rendererFor` reads
        /// when MapKit asks for a renderer.
        var routeTint: Color = RouteStyle.defaultTint
        var routeWidth: Double = RouteStyle.defaultWidth
        var routePattern: RouteLinePattern = RouteStyle.defaultPattern
        var highlightAnnotation: MKPointAnnotation?

        // MARK: Tracking button
        // Stored state for `MapCoordinator+TrackingButton.swift`, which owns
        // everything that reads it.

        var trackingBottomConstraint: NSLayoutConstraint?

        #if canImport(UIKit)
        /// The "my location" button itself, so the clamp that keeps it out of
        /// the top safe area can measure it rather than assume its size.
        weak var trackingButton: UIView?
        #endif

        weak var sheetMetrics: SheetMetrics?
        /// The map geometry the button was last positioned against, so repeated
        /// `update(_:_:)` calls during a sheet drag (where the map's own bounds
        /// haven't moved) can skip reapplying — the sheet observation already
        /// tracks `topY` at full frame rate on its own.
        ///
        /// The top inset is part of it because the button's upper limit is
        /// measured from it: a status bar that appears or disappears moves that
        /// limit without touching the map's height.
        var lastAppliedGeometry = (height: CGFloat(-1), topInset: CGFloat(-1))

        // MARK: Camera pill
        // Stored state for `MapPhotoControls.swift`. The pill rides the sheet
        // on the map's leading edge, at the same height and through the same
        // constraint arithmetic as the tracking button above — see
        // `applySheetTop(on:)`, which drives both.

        var photoControlsBottomConstraint: NSLayoutConstraint?

        #if os(iOS)
        weak var photoControls: MapPhotoControlsView?
        #endif

        // MARK: Attribution
        // Stored state for `MapAttributionView.swift`. The credit line hangs
        // beneath the weather badge and does not move with the sheet — see
        // `MapView.addAttribution`. What is stored is the one constraint that
        // is not a constant, and the two things that move it: whether there is
        // a badge above it at all, and how tall that badge draws.

        var attributionTopConstraint: NSLayoutConstraint?

        /// Whether the weather badge is on screen, mirrored from `MapView` so
        /// the Dynamic Type callback can reposition the line without it.
        var showsWeatherBadge = false

        #if os(iOS)
        /// Retains the Dynamic Type registration for the offset above; a
        /// dropped token unregisters it.
        var attributionTraitRegistration: (any UITraitChangeRegistration)?
        #endif

        #if canImport(UIKit)
        weak var attributionView: MapAttributionView?
        #endif

        weak var photoCaptureController: PhotoCaptureController?
        /// Guards `observePhotoControls` the same way `isObservingLocation`
        /// guards the location loop: a second registration would run a second
        /// fade animation over the first one's view.
        var isObservingPhotoControls = false

        // MARK: Photo pins
        // Stored state for `MapPhotoAnnotations.swift`, which owns everything
        // that reads it: the markers standing where this hike's photos were
        // taken, and the picture in each one's callout.

        var photoAnnotations: [PhotoMapAnnotation] = []
        weak var photoPinController: PhotoMapPinController?
        /// Guards `observePhotoPins` for the same reason the two flags above
        /// guard theirs — a second registration can never be cancelled.
        var isObservingPhotoPins = false
        /// The opacity the sheet's position alone calls for, remembered so a
        /// fade-in triggered by navigation mid-drag lands on it rather than on
        /// full opacity.
        var photoControlsSheetAlpha: CGFloat = 1

        /// Screen-point radius within which the selection dot and the "my location"
        /// puck are considered overlapping (roughly the size of either dot).
        static let overlapThresholdPoints: CGFloat = 20

        private static let routeInsetStandard: CGFloat = 60
        private static let routeInsetTop: CGFloat = 80
        private static let initialCenterMeters: CLLocationDistance = 2000
        private static let recordingAlpha: CGFloat = 0.9
        /// Internal alongside the threshold above, so the dot's own file can
        /// read them — see `MapCoordinator+Highlight.swift`.
        static let overlapFadedAlpha: CGFloat = 0.25

        /// Edge padding used whenever the map is fitted to the route.
        #if os(macOS)
        static let routeInsets = NSEdgeInsets(
            top: routeInsetStandard,
            left: routeInsetStandard,
            bottom: routeInsetStandard,
            right: routeInsetStandard
        )
        #else
        static let routeInsets = UIEdgeInsets(
            top: routeInsetTop,
            left: routeInsetStandard,
            bottom: routeInsetTop,
            right: routeInsetStandard
        )
        #endif

        /// Applies the current tint (with its alpha), width and line pattern to
        /// the route line. Everything the pattern decides is an ordinary stroke
        /// property except the chevrons, which the renderer draws itself.
        func applyStyle(to renderer: MKPolylineRenderer) {
            #if os(macOS)
            renderer.strokeColor = NSColor(routeTint)
            #else
            renderer.strokeColor = UIColor(routeTint)
            #endif
            renderer.lineWidth = CGFloat(routeWidth)
            renderer.lineJoin = .round
            renderer.lineCap = routePattern.lineCap
            let dashes = routePattern.dashLengths(forWidth: routeWidth)
            // `lineDashPattern` is an `[NSNumber]?`; an empty array is not a
            // documented way to say "unbroken", so a solid line clears it.
            // swiftlint:disable:next legacy_objc_type
            renderer.lineDashPattern = dashes.isEmpty ? nil : dashes.map { NSNumber(value: $0) }
            (renderer as? DirectionalPolylineRenderer)?.pattern = routePattern
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
            observeFollowUser(controller, on: mapView)
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

        private func observeFollowUser(_ controller: MapController, on mapView: MKMapView) {
            withObservationTracking {
                _ = controller.followUserRequest
            } onChange: { [weak self, weak mapView, weak controller] in
                let coordinator = self
                let map = mapView
                let model = controller
                Task { @MainActor in
                    guard let coordinator, let map, let model else { return }
                    map.setUserTrackingMode(.follow, animated: true)
                    coordinator.observeFollowUser(model, on: map)
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
        /// present, owns the viewport — that fix is spent rather than saved,
        /// so deselecting the route later doesn't let the next fix recentre a
        /// map the user has since panned somewhere else.
        private func centerOnUser(_ coordinate: CLLocationCoordinate2D?, on mapView: MKMapView) {
            guard let coordinate, !hasHandledFirstFix else { return }
            hasHandledFirstFix = true
            guard routeID == nil else { return }
            RenderSignpost.mark("MapCentered")
            let region = MKCoordinateRegion(
                center: coordinate,
                latitudinalMeters: Self.initialCenterMeters,
                longitudinalMeters: Self.initialCenterMeters
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

        /// Observes the drawn route's tint, width and line pattern and restyles
        /// the line imperatively, then re-registers — the same technique as
        /// `observeHighlight`, and for the same reason: both a colour well and a
        /// width slider are dragged, so their writes arrive at touch frequency
        /// and must not travel through SwiftUI to reach the map.
        func observeRouteStyle(_ style: RouteStyle, on mapView: MKMapView) {
            applyRouteStyle(tint: style.tint, width: style.width, pattern: style.pattern, on: mapView)
            withObservationTracking {
                _ = style.tint
                _ = style.width
                _ = style.pattern
            } onChange: { [weak self, weak mapView, weak style] in
                let coordinator = self
                let map = mapView
                let model = style
                Task { @MainActor in
                    guard let coordinator, let map, let model else { return }
                    coordinator.observeRouteStyle(model, on: map)
                }
            }
        }

        /// Restyles the drawn line (colour/alpha, width, and the highlight dot)
        /// without rebuilding the overlay — the route id hasn't changed.
        ///
        /// Safe to call before there is a line to restyle: with no renderer yet,
        /// recording the values is enough, because `rendererFor` styles the
        /// polyline from them when MapKit does ask for one.
        private func applyRouteStyle(
            tint: Color,
            width: Double,
            pattern: RouteLinePattern,
            on mapView: MKMapView
        ) {
            let tintChanged = routeTint != tint
            let widthChanged = routeWidth != width
            let patternChanged = routePattern != pattern
            guard tintChanged || widthChanged || patternChanged else { return }
            routeTint = tint
            routeWidth = width
            routePattern = pattern
            RenderSignpost.mark("MapRouteRestyled")
            if let renderer = routeRenderer {
                applyStyle(to: renderer)
                renderer.setNeedsDisplay()
            }
            // The inferred stretches follow the same tint and width, so a
            // colour drag has to reach them too — otherwise they keep the
            // previous hue until the selection changes and rebuilds them.
            for overlay in inferredRouteOverlays {
                guard let renderer = mapView.renderer(for: overlay)
                    as? MKPolylineRenderer else { continue }
                applyInferredStyle(to: renderer)
                renderer.setNeedsDisplay()
            }
            // And the paused ones, which follow the tint for the same reason.
            for overlay in pausedRouteOverlays {
                guard let renderer = mapView.renderer(for: overlay)
                    as? MKPolylineRenderer else { continue }
                applyPausedStyle(to: renderer)
                renderer.setNeedsDisplay()
            }
            // The dot and the photo markers mirror the tint (opaque); only
            // refresh them when the color moves.
            if tintChanged {
                refreshHighlightColor(on: mapView)
                refreshPhotoPinColor(on: mapView)
            }
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

        /// Applies the live recording's immutable chunks plus its bounded
        /// tail, then re-registers for the next revision.
        ///
        /// Owns three overlays, not the two the trace itself implies: the
        /// review segment (``recordingReviewOverlay``) is built, torn down
        /// and rendered from here too, because it is the same trace seen
        /// after the matcher has had its say.
        func observeRecordingTrace(_ trace: RecordingTrace, on mapView: MKMapView) {
            observedRecordingTrace = trace
            observedRecordingMapView = mapView
            startObservingScenePhaseIfNeeded()
            if isForeground {
                applyRecordingTrace(trace, on: mapView)
            } else {
                // Deliberately still re-registering below. The revision has to
                // keep being tracked or the map would never learn about the
                // fixes that arrived while it was away — the work is deferred,
                // not dropped.
                pendingRecordingTrace = true
            }
            withObservationTracking {
                _ = trace.revision
            } onChange: { [weak self, weak mapView, weak trace] in
                let coordinator = self
                let map = mapView
                let model = trace
                Task { @MainActor in
                    guard let coordinator, let map, let model else { return }
                    coordinator.observeRecordingTrace(model, on: map)
                }
            }
        }
    }
}

// MARK: - Recording trace overlays

/// Split out so the coordinator's own body stays inside its length limit;
/// this is the one part of the map that changes at GPS frequency, and it
/// reads better as a unit than buried among the other observers.
private extension MapView.Coordinator {
    /// Registers for the app-lifecycle notifications that gate the recording
    /// trace. Lazily, from `observeRecordingTrace`, because a map that never
    /// shows a recording never needs them.
    func startObservingScenePhaseIfNeeded() {
        #if os(iOS) || os(visionOS)
        guard scenePhaseObservers.isEmpty else { return }
        let center = NotificationCenter.default
        scenePhaseObservers = [
            center.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.isForeground = false }
            },
            center.addObserver(
                forName: UIApplication.willEnterForegroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.resumeForegroundDrawing() }
            },
        ]
        #endif
    }

    /// One catch-up pass for everything that arrived while the app was away.
    /// The trace is a snapshot of the whole recording rather than a stream of
    /// deltas, so an hour of pocket walking is caught up by a single apply
    /// rather than by one apply per fix.
    func resumeForegroundDrawing() {
        isForeground = true
        guard pendingRecordingTrace,
              let trace = observedRecordingTrace,
              let mapView = observedRecordingMapView
        else {
            pendingRecordingTrace = false
            return
        }
        pendingRecordingTrace = false
        applyRecordingTrace(trace, on: mapView)
    }

    func applyRecordingTrace(
        _ trace: RecordingTrace,
        on mapView: MKMapView
    ) {
        RenderSignpost.mark(
            "MapRecordingTraceApplied",
            "chunks=\(trace.committedChunks.count) tail=\(trace.tail.count)"
        )
        if recordingTraceGeneration != trace.generation {
            mapView.removeOverlays(recordingChunkOverlays)
            if let recordingTailOverlay {
                mapView.removeOverlay(recordingTailOverlay)
            }
            if let recordingReviewOverlay {
                mapView.removeOverlay(recordingReviewOverlay)
            }
            recordingChunkOverlays = []
            recordingTailOverlay = nil
            recordingReviewOverlay = nil
            recordingTraceGeneration = trace.generation
            // The overlays are gone, so the tokens describing what was
            // drawn describe nothing. Invalidate them, or the rebuilds
            // below will decide there is nothing to do.
            appliedTailRevision = nil
            appliedReviewRevision = nil
        }

        // No `count > 1` guard: the loop's index *is* `recordingChunkOverlays.count`,
        // so skipping a chunk would stall every later one forever. A chunk
        // is always `RecordingTrace.chunkSize` points by construction —
        // the trace seals one only when the stable tail has that many.
        while recordingChunkOverlays.count < trace.committedChunks.count {
            let coordinates = trace.committedChunks[recordingChunkOverlays.count]
            let overlay = MKPolyline(
                coordinates: coordinates,
                count: coordinates.count
            )
            recordingChunkOverlays.append(overlay)
            mapView.addOverlay(overlay, level: .aboveLabels)
        }

        // Guarded on the trace's own change tokens rather than rebuilt
        // unconditionally. `MKPolyline` is immutable, so "update the tail"
        // means allocating a new one and making MapKit drop and re-render
        // the old — the most expensive thing on the per-fix path. A
        // revision that moved the tail says nothing about the review
        // highlight, and vice versa; charging both for either is what this
        // avoids.
        if appliedTailRevision != trace.tailRevision {
            appliedTailRevision = trace.tailRevision
            if let recordingTailOverlay {
                mapView.removeOverlay(recordingTailOverlay)
                self.recordingTailOverlay = nil
            }
            if trace.tail.count > 1 {
                let tail = MKPolyline(
                    coordinates: trace.tail,
                    count: trace.tail.count
                )
                recordingTailOverlay = tail
                mapView.addOverlay(tail, level: .aboveLabels)
            }
        }

        if appliedReviewRevision != trace.reviewRevision {
            appliedReviewRevision = trace.reviewRevision
            if let recordingReviewOverlay {
                mapView.removeOverlay(recordingReviewOverlay)
                self.recordingReviewOverlay = nil
            }
            if trace.reviewSegment.count > 1 {
                let review = MKPolyline(
                    coordinates: trace.reviewSegment,
                    count: trace.reviewSegment.count
                )
                recordingReviewOverlay = review
                mapView.addOverlay(review, level: .aboveLabels)
            }
        }
    }
}

// MARK: - MKMapViewDelegate

extension MapView.Coordinator {
    func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
        guard !(annotation is MKUserLocation) else { return nil }
        if let photoAnnotation = annotation as? PhotoMapAnnotation {
            return photoAnnotationView(for: photoAnnotation, on: mapView)
        }

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
        let annotationShadowOpacity: Float = 0.3
        layer.shadowColor = CGColor(gray: 0, alpha: 1)
        layer.shadowOpacity = annotationShadowOpacity
        layer.shadowRadius = 2
        layer.shadowOffset = .zero
        return view
    }

    func mapView(_ mapView: MKMapView, didUpdate userLocation: MKUserLocation) {
        // Belt-and-suspenders alongside `didSelect` below — MapKit
        // resets this on its own internal user-location view, so it
        // alone doesn't reliably suppress the callout.
        mapView.view(for: userLocation)?.canShowCallout = false
        updateHighlightOpacity(on: mapView)
    }

    func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
        // `canShowCallout = false` doesn't reliably suppress MapKit's own
        // callout for the blue dot, so deselect immediately to dismiss it.
        guard view.annotation is MKUserLocation else { return }
        mapView.deselectAnnotation(view.annotation, animated: false)
    }

    func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
        // Zooming changes the on-screen distance between two fixed coordinates,
        // so the overlap fade needs to be re-checked, not just on move/relocate.
        updateHighlightOpacity(on: mapView)
    }

    func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
        if let matchedTileOverlay = overlay as? TileOverlay {
            return CachingTileOverlayRenderer(overlay: matchedTileOverlay)
        }
        if let polyline = overlay as? MKPolyline {
            if let renderer = walkHighlightRenderer(for: polyline) {
                return renderer
            }
            if recordingReviewOverlay === polyline {
                let renderer = MKPolylineRenderer(polyline: polyline)
                #if os(macOS)
                renderer.strokeColor = NSColor.systemOrange
                #else
                renderer.strokeColor = UIColor.systemOrange
                #endif
                renderer.lineWidth = 7
                renderer.lineDashPattern = [3, 5]
                renderer.lineJoin = .round
                renderer.lineCap = .round
                return renderer
            }
            if recordingTailOverlay === polyline
                || recordingChunkOverlays.contains(where: { $0 === polyline }) {
                let renderer = MKPolylineRenderer(polyline: polyline)
                #if os(macOS)
                renderer.strokeColor = NSColor.systemRed.withAlphaComponent(Self.recordingAlpha)
                #else
                renderer.strokeColor = UIColor.systemRed.withAlphaComponent(Self.recordingAlpha)
                #endif
                renderer.lineWidth = 4
                renderer.lineDashPattern = [10, 6]
                renderer.lineJoin = .round
                renderer.lineCap = .round
                return renderer
            }
            if inferredRouteOverlays.contains(where: { $0 === polyline }) {
                return inferredRouteRenderer(for: polyline)
            }
            if pausedRouteOverlays.contains(where: { $0 === polyline }) {
                let renderer = MKPolylineRenderer(polyline: polyline)
                applyPausedStyle(to: renderer)
                return renderer
            }
            let renderer = DirectionalPolylineRenderer(polyline: polyline)
            applyStyle(to: renderer)
            routeRenderer = renderer
            return renderer
        }
        return MKOverlayRenderer(overlay: overlay)
    }
}
