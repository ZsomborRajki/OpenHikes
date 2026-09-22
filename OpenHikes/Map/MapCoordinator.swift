//
//  MapCoordinator.swift
//  OpenHikes
//
//  MapView's MKMapViewDelegate: owns the map's overlays/annotations and
//  applies RouteHighlight/SheetMetrics/MapController/LocationManager changes
//  imperatively, keeping continuous updates entirely off SwiftUI's render path.
//

import MapKit
import OpenHikesShared
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
        /// The same, for which of the two buttons the capsule is showing — a
        /// second registration can never be cancelled. See
        /// ``observeLocationAccess(_:on:)``.
        var isObservingLocationAccess = false
        var routeID: UUID?
        var routeOverlay: MKPolyline?
        /// The drawn route's points, kept beside the polyline MapKit owns
        /// because the two are asked different questions — the same split, for
        /// the same reason, as ``CommunityRouteDrawing``: MapKit draws the
        /// first, and a tap projects the second through the map to find out
        /// what a thumb landed on. Reading them back out of an `MKPolyline`
        /// means a `getCoordinates` call into a buffer on every tap, for
        /// points this already had.
        var routeCoordinates: [CLLocationCoordinate2D] = []
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
        /// The lifecycle observations, held for exactly as long as the
        /// coordinator is — which is the whole of the deregistration.
        /// `NotificationCenter.ObservationToken` ends its observation when it
        /// goes out of scope, so releasing this array along with the
        /// coordinator is what takes both observers off the centre. That is
        /// why there is no `deinit` here at all any more, and with it went the
        /// `nonisolated(unsafe)` that the old untyped tokens needed purely so
        /// a nonisolated `deinit` could reach them.
        ///
        /// Stored rather than discarded for the same reason: a token dropped
        /// at the end of `startObservingScenePhaseIfNeeded` would take the
        /// registration down with it before the first fix ever arrived.
        /// `LifecycleObservationTokenTests` pins both halves of that, since
        /// neither is a `removeObserver` call a map test could watch.
        private var scenePhaseObservers: [NotificationCenter.ObservationToken] = []

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
        ///
        /// The glass capsule, not the `MKUserTrackingButton` inside it — see
        /// ``MapView/makeTrackingButton(for:_:)``. That is the view with the
        /// control's real size and the one the sheet moves and fades, and the
        /// tap-claim walk up the hierarchy reaches it from anything the button
        /// puts under a finger.
        weak var trackingButton: UIView?
        /// The button inside that capsule, held only to recolour its glyph as
        /// tracking turns on and off — see ``applyTrackingTint(for:)``.
        weak var trackingGlyph: MKUserTrackingButton?
        /// The one that takes its place when the hiker has refused location —
        /// see ``MapView/makeRefusedTrackingButton(_:)``. Exactly one of the
        /// two is ever on screen.
        weak var refusedTrackingButton: UIButton?
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

        // MARK: Side panel
        // The horizontal edges every control on the map hangs off: the safe
        // area, less the room ``MapSidePanel`` takes when landscape has swapped
        // the sheet for one. A guide of its own rather than an inset on the map
        // — `additionalSafeAreaInsets` belongs to `UIViewController`, and this
        // map is a `UIView` — so the two constants below are how the panel's
        // width reaches the tracking button, the camera pill and the credit
        // line. See `MapView.applySidePanelInset(_:)`.

        var controlsLeadingConstraint: NSLayoutConstraint?

        // MARK: Camera pill
        // Stored state for `MapPhotoControls.swift`. The pill sits on the
        // map's leading edge directly above the credit line, and rides the
        // sheet because the line does — see `MapView.addPhotoControls`. The
        // two constraints are the same relationship with and without a credit
        // to leave room for; exactly one is active at a time.

        var photoControlsAboveCreditLine: NSLayoutConstraint?
        var photoControlsWithoutCreditLine: NSLayoutConstraint?

        #if os(iOS)
        weak var photoControls: MapPhotoControlsView?
        #endif

        // MARK: Attribution
        // Stored state for `MapAttributionView.swift`. The credit line is the
        // bottom of that leading-edge stack and rides the sheet with the
        // tracking button opposite it — see `MapView.addAttribution`. What is
        // stored is the one constraint that is not a constant: its bottom,
        // which `applySheetTop(on:)` drives.

        var attributionBottomConstraint: NSLayoutConstraint?

        #if canImport(UIKit)
        weak var attributionView: MapAttributionView?
        #endif

        weak var photoCaptureController: PhotoCaptureController?
        /// Guards `observePhotoControls` the same way `isObservingLocation`
        /// guards the location loop: a second registration would run a second
        /// fade animation over the first one's view.
        var isObservingPhotoControls = false

        // MARK: Trail maker
        // Stored state for `MapTrailDraftControls.swift` and
        // `MapTrailDraftOverlay.swift`. The pill takes turns with the camera
        // one in the same slot above — offered on the inverse signal, so the
        // two can never both draw — and the line and its numbered pins are
        // drawn only while the maker's screen is up.

        #if os(iOS)
        weak var trailDraftControls: MapTrailDraftControlsView?
        #endif
        /// The same pair of constraints the camera pill has, against the same
        /// two anchors — a constraint belongs to one view, so the slot is
        /// shared by building it twice rather than by handing one over. See
        /// ``applyCreditLineClearance()``.
        var trailDraftAboveCreditLine: NSLayoutConstraint?
        var trailDraftWithoutCreditLine: NSLayoutConstraint?
        weak var trailDraftController: TrailDraftController?
        /// Guards `observeTrailDraftControls` for the reason the flag above
        /// guards its own — a second registration can never be cancelled.
        var isObservingTrailDraftControls = false
        /// The same, for the line and the pins.
        var isObservingTrailDraft = false
        /// One polyline per leg, since a leg is the thing that has a state —
        /// see `MapTrailDraftOverlay.swift` for what the three line weights
        /// mean.
        var trailDraftOverlays: [MKPolyline] = []
        /// Which state each of those should be drawn in, by object identity.
        ///
        /// Beside the overlays rather than on a subclass of `MKPolyline`, so
        /// every other thing that asks MapKit about an overlay keeps exactly
        /// one kind of answer to handle.
        var trailDraftLegStyles: [ObjectIdentifier: TrailLegSnap] = [:]
        var trailDraftAnnotations: [TrailDraftWaypointAnnotation] = []
        /// What the draft's lines currently correspond to, so a republish of
        /// the same draft removes and re-adds nothing. The legs rather than
        /// the points, because an answer landing changes a leg's shape and
        /// state without any point moving.
        var trailDraftLegs: [TrailLeg] = []
        /// And where the pins currently are. Also what a press is measured
        /// against to find the waypoint under it — see `MapTrailDraftDrag.swift`.
        var trailDraftCoordinates: [CLLocationCoordinate2D] = []
        /// The provisional pin a tap left behind, waiting for one of its
        /// callout's buttons — or `nil`, which is nearly always.
        ///
        /// Held by the map rather than by the draft, because nothing about it
        /// is part of the trail: it is a question, and the map is what puts it
        /// away. See `MapTrailDraftCallout.swift`.
        var trailDraftDroppedPin: TrailDraftDroppedPin?
        /// The places marked along the drawing, as the map has drawn them.
        /// Editable: the maker is up.
        var trailDraftPlaceAnnotations: [TrailPlaceAnnotation] = []
        /// The places of the hike whose screen is pushed, as the map has drawn
        /// them. Read-only, and never on screen at the same time as the pair
        /// above — the maker and a hike's detail are two different screens, and
        /// ``TrailPlacePinController`` withdraws these the moment its own is
        /// not on top.
        var hikePlaceAnnotations: [TrailPlaceAnnotation] = []
        var isObservingHikePlaces = false
        weak var hikePlaceController: TrailPlacePinController?
        /// What OpenStreetMap last offered near the drawing, as the map has
        /// drawn it. Nothing here is in the draft — see
        /// `MapTrailPointCandidates.swift`.
        var trailPointCandidateAnnotations: [TrailPointCandidateAnnotation] = []

        #if canImport(UIKit)
        /// The maker's own *Search this area*. A second instance of the
        /// Community tab's control, never on screen at the same time as it —
        /// see `MapTrailPointSearchControl.swift`.
        weak var trailPointSearchControl: MapAreaSearchView?
        #endif
        /// Guards `observeTrailPointSearch` the way every other flag here
        /// guards its own — a second registration can never be cancelled.
        var isObservingTrailPointSearch = false

        #if canImport(UIKit)
        /// The press that moves a waypoint, or `nil` before the map has one.
        /// Held so installing it twice cannot take hold of one pin twice —
        /// see `MapTrailDraftDrag.swift`.
        var trailDraftDragRecognizer: UILongPressGestureRecognizer?
        #endif

        /// The point currently being dragged, as the map has drawn it. The
        /// draft's own untracked channel is the source; this is what the last
        /// pass applied, so a restore knows which pin and which two lines to
        /// put back.
        var trailDraftDrag: TrailWaypointDrag?
        /// How far the pin was from the finger when the press was recognized,
        /// carried for the rest of the gesture so the point does not jump.
        var trailDraftDragOffset: CGSize = .zero
        /// Whether this drag is the reason the map is not scrolling, so a map
        /// that was already still is handed back the way it was found.
        var trailDraftDragPausedScrolling = false
        /// The place pin currently under a finger, or `nil`.
        ///
        /// The annotation itself rather than an index or a coordinate, because
        /// moving a place *is* writing this object's coordinate — nothing is
        /// published and nothing is redrawn until the finger lifts. See
        /// `MapTrailPlaceDrag.swift`.
        var trailPlaceDrag: TrailPlaceAnnotation?

        // MARK: Photo pins
        // Stored state for `MapPhotoAnnotations.swift`, which owns everything
        // that reads it: the markers standing where this hike's photos were
        // taken, and the picture in each one's callout.

        var photoAnnotations: [PhotoMapAnnotation] = []
        weak var photoPinController: PhotoMapPinController?
        /// The last ``PinSelection`` token a pin actually answered, so a
        /// republish of the same pins does not reopen a callout the hiker has
        /// since dismissed. See `applyPhotoPinSelection(_:on:)`.
        var appliedPhotoPinSelection: Int?
        /// Guards `observePhotoPins` for the same reason the two flags above
        /// guard theirs — a second registration can never be cancelled.
        var isObservingPhotoPins = false
        /// The opacity the sheet's position alone calls for, remembered so a
        /// fade-in triggered by navigation mid-drag lands on it rather than on
        /// full opacity.
        var photoControlsSheetAlpha: CGFloat = 1

        // MARK: Community
        // Stored state for `MapCommunityAnnotations.swift` and
        // `MapCommunitySearchControl.swift`, which own everything that reads
        // it: the markers standing where the shared hikes in the list are, and
        // the button that offers to look somewhere else.

        /// Told where the map settled, in `regionDidChangeAnimated`, and read
        /// back for what the map is currently offering to do about it.
        ///
        /// `weak` like every other controller the coordinator points at: it is
        /// owned by ``OpenHikesModel`` and outlives this map, and a strong
        /// reference here would be the map keeping a model alive rather than
        /// the other way round.
        weak var community: CommunityBrowser?
        /// Told where the map came to rest so place search is asked about the
        /// map the hiker is looking at. Weak for the same reason
        /// ``community`` is: the coordinator outlives nothing and owns
        /// nothing.
        weak var searchCompleter: SearchCompleter?

        var communityAnnotations: [CommunityMapAnnotation] = []
        /// The markers standing where the *open preview's* photographs were
        /// taken — see `MapCommunityPhotoAnnotations.swift`, which owns
        /// everything that reads this. Empty whenever no preview is up, which
        /// is almost always.
        var communityPhotoAnnotations: [CommunityPhotoMapAnnotation] = []
        /// The last ``CommunityPhotoPinSelection`` token a pin answered — the
        /// counterpart of ``appliedPhotoPinSelection``, and for the same reason.
        var appliedCommunityPhotoPinSelection: Int?
        /// The shared hikes' own lines, drawn faded beneath the hiker's route
        /// — see `MapCommunityRoutes.swift`, which owns everything that reads
        /// this.
        var communityRoutes: [CommunityRouteDrawing] = []
        /// Guards `observeCommunityPins` the way the photo flags guard theirs —
        /// a second registration can never be cancelled.
        var isObservingCommunityPins = false
        /// The same, for the previewed hike's photo pins.
        var isObservingCommunityPhotoPins = false
        /// The same, for the lines.
        var isObservingCommunityRoutes = false
        /// The same, for the *Search this area* pill's visibility.
        var isObservingAreaPrompt = false
        /// Whether a callout is open, which the pill has to get out of the way
        /// of — see `withdrawAreaSearchForCallout(on:)`.
        var hasOpenCallout = false
        /// Whether the trail maker has the strip at the top of the map, which
        /// is the one exclusion in this feature that does not fall out of an
        /// existing definition — see `withdrawAreaSearchForDrawing(_:)`.
        var isDrawingTrail = false
        /// The last preview the camera was moved for, so opening one hike
        /// fits its route once rather than on every later rebuild.
        var fittedPreviewListingID: String?

        /// Where a tap on the hiker's own drawn route goes. Weak for the
        /// reason ``community`` is: the coordinator outlives nothing and owns
        /// nothing. See ``DrawnRouteTap``.
        weak var drawnRouteTap: DrawnRouteTap?

        /// What the refused "my location" button raises. Weak for the reason
        /// above, and handed over rather than observed in this direction: the
        /// map tells it a refused button was tapped and it never tells the map
        /// anything. See ``LocationAccessPrompt``.
        weak var locationAccessPrompt: LocationAccessPrompt?

        #if canImport(UIKit)
        /// The recognizer that answers a tap on any line drawn here, held so
        /// installing it twice cannot open one screen twice. MapKit hit-tests
        /// annotations and never overlays, so this is the whole of how a line
        /// is tappable at all — see `MapCoordinator+RouteTap.swift`.
        var routeTapRecognizer: UITapGestureRecognizer?
        #endif

        #if canImport(UIKit)
        weak var areaSearchControl: MapAreaSearchView?
        #endif

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

        /// Width occupied beyond the safe leading edge by the landscape panel.
        var sidePanelInset: CGFloat = 0

        /// Observes the detail view / search commands and applies them imperatively.
        /// Each command re-registers only its own tracking (bumping one must not
        /// re-arm the others, or they'd multiply).
        func observeMapController(_ controller: MapController, on mapView: MKMapView) {
            observeFitRoute(controller, on: mapView)
            observeShowRegion(controller, on: mapView)
            observeFollowUser(controller, on: mapView)
        }

        private func observeFitRoute(_ controller: MapController, on mapView: MKMapView) {
            reobserving(self, mapView, controller) {
                _ = controller.fitRouteRequest
            } onChange: { coordinator, map, model in
                coordinator.fitToCurrentRoute(map, animated: true)
                coordinator.observeFitRoute(model, on: map)
            }
        }

        private func observeShowRegion(_ controller: MapController, on mapView: MKMapView) {
            reobserving(self, mapView, controller) {
                _ = controller.showRegionRequest
            } onChange: { coordinator, map, model in
                if let region = model.region {
                    // Through the coordinator rather than `setRegion`, so a
                    // searched place and a photograph's pin land in the map
                    // the hiker can see rather than in the window — see
                    // `MapCoordinator+RouteFitting.swift`. `setRegion` has no
                    // edge padding at all, which is what put a result's
                    // centre behind the sheet.
                    coordinator.show(region, on: map, animated: true)
                }
                coordinator.observeShowRegion(model, on: map)
            }
        }

        private func observeFollowUser(_ controller: MapController, on mapView: MKMapView) {
            reobserving(self, mapView, controller) {
                _ = controller.followUserRequest
            } onChange: { coordinator, map, model in
                map.setUserTrackingMode(.follow, animated: true)
                coordinator.observeFollowUser(model, on: map)
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
            reobserving(self, mapView, locationManager) {
                _ = locationManager.coordinate
            } onChange: { coordinator, map, model in
                coordinator.trackLocation(model, on: map)
            }
        }

        /// Centers the map on the user's first fix, once. A route, once
        /// present, owns the viewport — that fix is spent rather than saved,
        /// so deselecting the route later doesn't let the next fix recentre a
        /// map the user has since panned somewhere else.
        ///
        /// **The one camera move that does not go through the focus area**, and
        /// the exception is the sheet rather than this. Every other move is
        /// asked for by something that also puts the sheet at its middle detent
        /// — see ``SheetPresentation/makeRoomForTheMap()`` — which is what makes
        /// framing against that detent right. A first fix is asked for by
        /// nobody: the app has just launched, the sheet is at its *compact*
        /// detent and is eighty points tall, and nothing here should raise it.
        /// Reserving a middle detent's worth of room against a sheet that small
        /// would squeeze the hiker's surroundings into the top of the screen and
        /// leave the bottom half empty.
        private func centerOnUser(_ coordinate: CLLocationCoordinate2D?, on mapView: MKMapView) {
            guard let coordinate, !hasHandledFirstFix else { return }
            hasHandledFirstFix = true
            guard routeID == nil else { return }
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
            reobserving(self, mapView, style) {
                _ = style.tint
                _ = style.width
                _ = style.pattern
            } onChange: { coordinator, map, model in
                coordinator.observeRouteStyle(model, on: map)
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
            reobserving(self, mapView, highlight) {
                _ = highlight.coordinate
            } onChange: { coordinator, map, model in
                coordinator.observeHighlight(model, on: map)
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
            reobserving(self, mapView, trace) {
                _ = trace.revision
            } onChange: { coordinator, map, model in
                coordinator.observeRecordingTrace(model, on: map)
            }
        }
    }
}

// MARK: - Recording trace overlays

/// Split out so the coordinator's own body stays inside its length limit;
/// this is the one part of the map that changes at GPS frequency, and it
/// reads better as a unit than buried among the other observers.
private extension MapView.Coordinator {
    /// Registers for the app-lifecycle messages that gate the recording
    /// trace. Lazily, from `observeRecordingTrace`, because a map that never
    /// shows a recording never needs them.
    ///
    /// Typed `MainActorMessage` observers rather than named notifications:
    /// the handler is synchronously main-actor isolated, which is what removes
    /// the `MainActor.assumeIsolated` these two used to open with. That the
    /// body runs *in* the post rather than a turn later is load-bearing rather
    /// than tidy — a fix already in flight would otherwise be drawn after the
    /// app had gone away — so it is pinned rather than assumed, by
    /// `MapCoordinatorLifecycleTests.lifecycleGateMovesSynchronously`. Neither
    /// handler may grow a hop of its own.
    ///
    /// No subject is passed, so the registration is not scoped to
    /// `UIApplication.shared`. There is exactly one application object in the
    /// process, so scoping buys nothing in the app and costs interoperability
    /// with an untyped post carrying no object — which is how
    /// `MapCoordinatorLifecycleTests` drives this gate, having no way to
    /// background a test host.
    func startObservingScenePhaseIfNeeded() {
        #if os(iOS) || os(visionOS)
        guard scenePhaseObservers.isEmpty else { return }
        let center = NotificationCenter.default
        scenePhaseObservers = [
            center.addObserver(
                for: UIApplication.DidEnterBackgroundMessage.self
            ) { [weak self] _ in
                self?.isForeground = false
            },
            center.addObserver(
                for: UIApplication.WillEnterForegroundMessage.self
            ) { [weak self] _ in
                self?.resumeForegroundDrawing()
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
        // MapKit's own, for a label a tap selected while drawing — it is
        // deselected at once. See `MapTrailDraftFeatures.swift`.
        guard !(annotation is MKUserLocation), !(annotation is MKMapFeatureAnnotation) else { return nil }
        if let photoAnnotation = annotation as? PhotoMapAnnotation {
            return photoAnnotationView(for: photoAnnotation, on: mapView)
        }
        if let communityAnnotation = annotation as? CommunityMapAnnotation {
            return communityAnnotationView(for: communityAnnotation, on: mapView)
        }
        if let communityPhoto = annotation as? CommunityPhotoMapAnnotation {
            return communityPhotoAnnotationView(for: communityPhoto, on: mapView)
        }
        // The maker's three kinds in one question — see
        // ``makerAnnotationView(for:on:)``.
        if let maker = makerAnnotationView(for: annotation, on: mapView) { return maker }

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
        // A label on the map, tapped while drawing, becomes the maker's pin.
        if selectTrailDraftFeature(view.annotation, on: mapView) { return }
        // `canShowCallout = false` doesn't reliably suppress MapKit's own
        // callout for the blue dot, so deselect immediately to dismiss it.
        guard view.annotation is MKUserLocation else {
            // `canShowCallout` because a selection is not a callout: the route
            // highlight's own dots are selectable and draw nothing, and a tap
            // on one that took *Search this area* away would be the pill
            // getting out of the way of something that is not there.
            withdrawAreaSearchForCallout(open: view.canShowCallout)
            // The same `canShowCallout` question, for the same reason: a
            // highlight dot is selectable and draws nothing, and a tap that
            // opened no callout has nothing to confirm.
            if view.canShowCallout { HapticMoment.targetHit.play() }
            return
        }
        mapView.deselectAnnotation(view.annotation, animated: false)
    }

    /// The other half of the line above: the pill comes back when the callout
    /// the hiker was reading goes.
    func mapView(_ mapView: MKMapView, didDeselect view: MKAnnotationView) {
        guard !(view.annotation is MKUserLocation) else { return }
        withdrawAreaSearchForCallout(open: false)
        // A dismissed callout is the hiker saying *never mind*, so the
        // provisional pin it belonged to goes with it.
        dismissTrailDraftPin(for: view.annotation, on: mapView)
    }

    #if canImport(UIKit)
    /// The way in from a shared hike's callout — see
    /// ``communityAnnotationView(for:on:)``.
    ///
    /// The callout is closed before the preview opens, for the reason a photo
    /// pin's is: it belongs to a map the sheet is about to cover, and one left
    /// standing is what the hiker comes back to when they pop the screen.
    func mapView(
        _ mapView: MKMapView,
        annotationView view: MKAnnotationView,
        calloutAccessoryControlTapped control: UIControl
    ) {
        guard let annotation = view.annotation as? CommunityMapAnnotation else { return }
        mapView.deselectAnnotation(annotation, animated: true)
        community?.open(annotation.listing)
    }
    #endif

    func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
        // Zooming changes the on-screen distance between two fixed coordinates,
        // so the overlap fade needs to be re-checked, not just on move/relocate.
        updateHighlightOpacity(on: mapView)
        // The community list follows the map, and this is the only place it
        // learns the map moved. Deliberately the *settled* region rather than
        // `mapViewDidChangeVisibleRegion`, which fires continuously through a
        // pan: a hiker dragging across a county would otherwise ask a
        // question per frame. What arrives here is still filtered again by
        // ``CommunityQueryPolicy`` before anything reaches the network, and
        // costs a comparison while browsing is off.
        community?.regionDidSettle(mapView.region)
        // And the trail maker's own area search, which asks a different
        // service about a smaller box and is otherwise the same offer. Nothing
        // reaches the network here either: it is a comparison, and a tap is
        // what spends a request. See ``TrailPointFinder/regionDidSettle(_:)``.
        trailDraftController?.finder.regionDidSettle(mapView.region)
        // And place search, which asked the one location question in the app
        // that was never told where the hiker was.
        searchCompleter?.regionDidSettle(mapView.region)
    }

    func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
        if let matchedTileOverlay = overlay as? TileOverlay {
            return CachingTileOverlayRenderer(overlay: matchedTileOverlay)
        }
        if let polyline = overlay as? MKPolyline {
            if let renderer = walkHighlightRenderer(for: polyline) {
                return renderer
            }
            // Before every style below, which all describe the hiker's own
            // route: a shared hike's line is not it and must not be drawn in
            // the colour and width they chose for theirs.
            if let renderer = communityRouteRenderer(for: polyline) {
                return renderer
            }
            // And the trail being drawn, which is not a hike at all yet.
            if let renderer = trailDraftRenderer(for: polyline) {
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
