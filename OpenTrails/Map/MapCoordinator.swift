//
//  MapCoordinator.swift
//  OpenTrails
//
//  MapView's MKMapViewDelegate: owns the map's overlays/annotations and
//  applies RouteHighlight/SheetMetrics/MapController/LocationManager changes
//  imperatively, keeping continuous updates entirely off SwiftUI's render path.
//

import MapKit
import SwiftUI

extension MapView {
    final class Coordinator: NSObject, MKMapViewDelegate {
        var hasCentered = false
        /// Guards `observeLocation` so `update(_:_:)` — called on every
        /// SwiftUI-driven pass — only starts the location-tracking loop once.
        private var isObservingLocation = false
        var routeID: UUID?
        var routeOverlay: MKPolyline?
        var recordingChunkOverlays: [MKPolyline] = []
        var recordingTailOverlay: MKPolyline?
        var recordingReviewOverlay: MKPolyline?
        private var recordingTraceGeneration = -1
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
        var highlightAnnotation: MKPointAnnotation?
        var trackingBottomConstraint: NSLayoutConstraint?
        private weak var sheetMetrics: SheetMetrics?
        /// Screen-point radius within which the selection dot and the "my location"
        /// puck are considered overlapping (roughly the size of either dot).
        static let overlapThresholdPoints: CGFloat = 20

        private static let routeInsetStandard: CGFloat = 60
        private static let routeInsetTop: CGFloat = 80
        private static let initialCenterMeters: CLLocationDistance = 2000
        private static let sheetFallbackOffset: CGFloat = 92
        private static let annotationDiameter: CGFloat = 18
        private static let annotationBorderWidth: CGFloat = 3
        private static let annotationShadowOpacity: Float = 0.3
        private static let annotationShadowRadius: CGFloat = 2
        private static let recordingAlpha: CGFloat = 0.9
        private static let overlapFadedAlpha: CGFloat = 0.25

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
        /// present, owns the viewport — don't also recenter on the user.
        private func centerOnUser(_ coordinate: CLLocationCoordinate2D?, on mapView: MKMapView) {
            guard routeID == nil, let coordinate, !hasCentered else { return }
            hasCentered = true
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
            let sheetTop = reportedTop > 0 ? reportedTop : height - Self.sheetFallbackOffset
            constraint.constant = max(sheetTop, height * 0.5) - spacing
        }

        /// Observes the drawn route's tint and width and restyles the line
        /// imperatively, then re-registers — the same technique as
        /// `observeHighlight`, and for the same reason: both a colour well and a
        /// width slider are dragged, so their writes arrive at touch frequency
        /// and must not travel through SwiftUI to reach the map.
        func observeRouteStyle(_ style: RouteStyle, on mapView: MKMapView) {
            applyRouteStyle(tint: style.tint, width: style.width, on: mapView)
            withObservationTracking {
                _ = style.tint
                _ = style.width
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
        private func applyRouteStyle(tint: Color, width: Double, on mapView: MKMapView) {
            let tintChanged = routeTint != tint
            let widthChanged = routeWidth != width
            guard tintChanged || widthChanged else { return }
            routeTint = tint
            routeWidth = width
            RenderSignpost.mark("MapRouteRestyled")
            if let renderer = routeRenderer {
                applyStyle(to: renderer)
                renderer.setNeedsDisplay()
            }
            // The dot mirrors the tint (opaque); only refresh it when the color moves.
            if tintChanged { refreshHighlightColor(on: mapView) }
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

        /// Applies the live recording's immutable chunks plus its bounded tail,
        /// then re-registers for the next revision.
        func observeRecordingTrace(_ trace: RecordingTrace, on mapView: MKMapView) {
            applyRecordingTrace(trace, on: mapView)
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

        private func applyRecordingTrace(
            _ trace: RecordingTrace,
            on mapView: MKMapView
        ) {
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
            }

            // No `count > 1` guard: the loop's index *is* `recordingChunkOverlays.count`,
            // so skipping a chunk would stall every later one forever. A chunk
            // is always `RecordingTrace.chunkSize` points by construction —
            // both `append` and `replace(with:)` only ever commit full ones.
            while recordingChunkOverlays.count < trace.committedChunks.count {
                let coordinates = trace.committedChunks[recordingChunkOverlays.count]
                let overlay = MKPolyline(
                    coordinates: coordinates,
                    count: coordinates.count
                )
                recordingChunkOverlays.append(overlay)
                mapView.addOverlay(overlay, level: .aboveLabels)
            }

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

// MARK: - Highlight annotation

private extension MapView.Coordinator {
    /// Adds/moves/removes the single highlight annotation. O(1).
    func applyHighlight(_ coordinate: CLLocationCoordinate2D?, on mapView: MKMapView) {
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
    func updateHighlightOpacity(on mapView: MKMapView) {
        guard let annotation = highlightAnnotation,
              let view = mapView.view(for: annotation) else { return }
        guard let userCoordinate = mapView.userLocation.location?.coordinate else {
            setAlpha(1, on: view)
            return
        }
        let selectionPoint = mapView.convert(annotation.coordinate, toPointTo: mapView)
        let userPoint = mapView.convert(userCoordinate, toPointTo: mapView)
        let distance = hypot(selectionPoint.x - userPoint.x, selectionPoint.y - userPoint.y)
        setAlpha(distance < Self.overlapThresholdPoints ? Self.overlapFadedAlpha : 1, on: view)
    }

    func setAlpha(_ alpha: CGFloat, on view: MKAnnotationView) {
        #if os(macOS)
        view.alphaValue = alpha
        #else
        view.alpha = alpha
        #endif
    }
}

// MARK: - MKMapViewDelegate

extension MapView.Coordinator {
    func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
        guard !(annotation is MKUserLocation) else { return nil }

        let identifier = "routeHighlight"
        let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier)
            ?? MKAnnotationView(annotation: annotation, reuseIdentifier: identifier)
        view.annotation = annotation
        view.canShowCallout = false

        // A small filled dot in the route tint with a white ring.
        let diameter: CGFloat = Self.annotationDiameter
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
        layer.borderWidth = Self.annotationBorderWidth
        layer.shadowColor = CGColor(gray: 0, alpha: 1)
        layer.shadowOpacity = Self.annotationShadowOpacity
        layer.shadowRadius = Self.annotationShadowRadius
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
        // MapKit's default callout for the blue dot pulls in the "Me"
        // contact's photo (or a placeholder silhouette) from Contacts;
        // `canShowCallout = false` alone doesn't reliably suppress it,
        // so deselect immediately to dismiss the callout before it shows.
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
