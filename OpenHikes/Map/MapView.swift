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

    /// The stretches a finished walk covered. Observed directly by the map
    /// (not via SwiftUI) so the Walk Summary's *Show on Map* adds a handful of
    /// polylines without re-rendering any view — see ``WalkHighlight``.
    var walkHighlight: WalkHighlight

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

    /// Where a tap on the drawn route above goes.
    ///
    /// Handed over rather than observed, and in this direction only: the map
    /// tells it a line was tapped and it never tells the map anything. See
    /// ``DrawnRouteTap``, and ``community`` below for the same arrangement
    /// serving the shared hikes' lines.
    var drawnRouteTap: DrawnRouteTap

    /// Where a tap on the *refused* "my location" button goes — the capsule
    /// the map shows in place of MapKit's own when the hiker has said no.
    ///
    /// Handed over in the same direction and for the same reason as
    /// ``drawnRouteTap``. Which of the two buttons is on screen is a separate
    /// question, and it is read from ``locationManager`` above rather than
    /// passed here — see ``Coordinator/observeLocationAccess(_:on:)``.
    var locationAccessPrompt: LocationAccessPrompt

    /// Whether a photo can be taken right now, and the two requests the camera
    /// pill raises. Observed directly by the map (not via SwiftUI) so pushing
    /// or popping a screen that can receive a photo shows or hides the pill
    /// without an update pass — see ``MapPhotoControlsView``.
    var photoCapture: PhotoCaptureController

    /// Where the open hike's photos were taken. Observed directly by the map
    /// (not via SwiftUI) so taking, importing or deleting one redraws MapKit's
    /// annotations rather than this view — see ``PhotoMapPinController``.
    var photoPins: PhotoMapPinController
    /// The open hike's marked places, drawn as pins. Observed directly for the
    /// reason ``photoPins`` is — see ``TrailPlacePinController``.
    var placePins: TrailPlacePinController

    /// Whether a trail can be made right now, and the line being drawn if one
    /// is. Observed directly by the map (not via SwiftUI) so putting a point
    /// down moves MapKit and nothing else — see ``TrailDraftController``.
    var trailMaker: TrailDraftController

    /// Told where the map came to rest, so community results can follow the
    /// map without any SwiftUI body reading the region.
    ///
    /// Handed over rather than observed, and in this direction only: the
    /// browser never tells the map anything. A region reaches it on every
    /// settle and is dropped by ``CommunityQueryPolicy`` unless it is worth a
    /// request — see ``CommunityBrowser/regionDidSettle(_:)``, which is a
    /// stored property write and a comparison while browsing is off.
    var community: CommunityBrowser

    /// Told where the map came to rest, so the search field's suggestions and
    /// a typed Return are both answered near the map rather than globally.
    ///
    /// Handed over rather than observed, in this direction only, for the same
    /// reason ``community`` is — see ``SearchCompleter/regionDidSettle(_:)``.
    var searchCompleter: SearchCompleter

    /// How far the landscape side panel reaches in from the leading edge, or
    /// zero in portrait where there is no panel and the sheet is over the map
    /// instead.
    ///
    /// Spent on the layout guide the map's own controls hang off — see
    /// ``applySidePanelInset(_:)`` — so the credit line and the camera pill
    /// sit beside ``MapSidePanel`` rather than behind it, while the map itself
    /// stays full-bleed underneath. It is a guide rather than an inset on the
    /// map because `additionalSafeAreaInsets` belongs to `UIViewController`
    /// and this map is a `UIView`; and it is passed down rather than derived
    /// here because what reaches `MKMapView.safeAreaInsets` comes from the
    /// window, which knows nothing about a panel SwiftUI drew over it.
    ///
    /// A rotation is the only thing that changes it, so unlike the reference
    /// types above it is a plain value compared in `==` below.
    var sidePanelInset: CGFloat = 0

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Internal rather than private so `MapCoordinatorTests` can drive the two
    /// entry points SwiftUI drives — building the map and updating it — against
    /// a real `MKMapView`. Everything below them stays private.
    func makeMapView(_ coordinator: Coordinator) -> MKMapView {
        // Fires once per MKMapView creation — if this repeats, something is
        // destroying the representable's identity (e.g. an `.id()` upstream
        // churning), which throws away all MapKit state, not just SwiftUI's.
        // The launch is over when the app has nothing left to do before the
        // map, not when there is a frame: `histogrammedTimeToFirstDraw` stops
        // at the first CA commit, which on this app is a sheet over an empty
        // map. Deliberately above `MKMapView()` rather than below it — the
        // boundary is the hand-off to MapKit, and what MapKit then costs is
        // not this app's work to shorten. See `LaunchMeasurement`.
        LaunchMeasurement.finish()
        let mapView = MKMapView()
        mapView.delegate = coordinator
        mapView.showsUserLocation = true
        mapView.pointOfInterestFilter = .includingAll
        coordinator.observeHighlight(highlight, on: mapView)
        coordinator.observeWalkHighlight(walkHighlight, on: mapView)
        coordinator.observeRecordingTrace(recordingTrace, on: mapView)
        coordinator.observeSheetMetrics(sheetMetrics, on: mapView)
        coordinator.observeMapController(mapController, on: mapView)
        coordinator.observeRouteStyle(routeStyle, on: mapView)
        coordinator.observePhotoPins(photoPins, on: mapView)
        coordinator.observeHikePlaces(placePins, on: mapView)
        #if os(iOS)
        coordinator.observeTrailDraftTint(on: mapView)
        #endif
        coordinator.community = community
        coordinator.searchCompleter = searchCompleter
        coordinator.drawnRouteTap = drawnRouteTap
        coordinator.locationAccessPrompt = locationAccessPrompt
        // The map asks the community question and now draws its answer too —
        // see ``MapCommunityAnnotations``. Observed here rather than handed
        // down, so a nearby result landing moves MapKit's annotations and no
        // SwiftUI view.
        coordinator.observeCommunityPins(community, on: mapView)
        // And where the open preview's photographs were taken, which is the
        // half of a shared hike's pictures the strip on the sheet cannot say —
        // see ``MapCommunityPhotoAnnotations``.
        coordinator.observeCommunityPhotoPins(community, on: mapView)
        // And where they go, which is the half a pin cannot say — see
        // ``MapCommunityRoutes``. The recognizer goes on with them: MapKit
        // hit-tests annotations and never overlays, so without it every line
        // here — theirs and the hiker's own — would be scenery. One
        // recognizer answers for both; see `MapCoordinator+RouteTap.swift`.
        coordinator.observeCommunityRoutes(community, on: mapView)
        #if canImport(UIKit)
        coordinator.installRouteTap(on: mapView)
        // And the press that moves a point already down. A separate
        // recognizer rather than more of the one above, because it answers a
        // different gesture and begins only over one of the maker's own pins —
        // see `MapTrailDraftDrag.swift`.
        coordinator.installTrailDraftDrag(on: mapView)
        // And the press that drops a pin, which begins everywhere the one
        // above does not — see `MapTrailDraftSelection.swift`.
        coordinator.installTrailDraftPinDrop(on: mapView)
        #endif

        // Raster tiles from the selected provider, replacing Apple's base map.
        applyTileSource(to: mapView, coordinator)

        addControls(to: mapView, coordinator)

        // After `addControls`, deliberately: the pill's first visibility pass
        // needs the view to exist, or a screen that is already offering one
        // when the map is built (a restored selection, a widget deep link)
        // leaves it hidden until the *next* availability change.
        coordinator.observePhotoControls(photoCapture)
        // And the pill that takes turns with it in the same slot, for the same
        // reason: a map built while the sheet already has nothing pushed has
        // to offer the maker on this first pass rather than waiting for a
        // navigation that may not come.
        coordinator.observeTrailDraftControls(trailMaker)
        // The line and its numbered pins, which are drawn only while the
        // maker's screen is up — including on a map rebuilt underneath one, as
        // a rotation rebuilds it.
        coordinator.observeTrailDraft(trailMaker, on: mapView)
        // After `addControls` for the same reason: this decides which of the
        // two buttons in the tracking capsule is on screen, and neither
        // exists until that call has run. A map built by a hiker who refused
        // location months ago has to draw the refused one on this first pass
        // — there is no authorization change coming to prompt a second.
        #if canImport(UIKit)
        coordinator.observeLocationAccess(locationManager, on: mapView)
        #endif
        // The same, for the same reason: a map rebuilt while an offer is
        // standing has to draw it on this first pass rather than waiting for
        // the next settle.
        coordinator.observeAreaPrompt(community)
        // And the maker's own pill, for the same reason: a map rebuilt while
        // the maker is open — a rotation does exactly that — has to draw it on
        // this first pass rather than waiting for a navigation that will not
        // come.
        coordinator.observeTrailPointSearch(trailMaker)

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
        // Apple's labels are only tappable where they are drawn.
        defer { coordinator.refreshTrailDraftFeatureSelection(on: mapView) }

        #if os(iOS)
        // The chrome on this map follows the *map*, not the interface.
        //
        // Every raster provider here is light-styled at every hour —
        // `openStreetMap`, `stadiaOutdoors` and `thunderforestOutdoors` all
        // draw a whiteish page in either appearance — so in dark mode the
        // controls over them were resolving dark against light tiles. The
        // tracking button's glass came out mid-grey with a white arrow on it,
        // 2.25:1, and the camera and *Search this area* pills did the same.
        // Forcing the light appearance for as long as those tiles are drawn
        // puts every control back on the side of the contrast it was designed
        // for: 17.5:1 for that arrow, measured.
        //
        // `.unspecified` for the system base map, and that is the whole reason
        // this is decided here rather than once at build time: `appleMaps` is
        // the one provider that *does* turn over with the appearance, so it is
        // also the one whose chrome should.
        mapView.overrideUserInterfaceStyle = tileSource == nil ? .unspecified : .light
        #endif

        // Before the early return below: the system base map is a change of
        // credit too — MapKit draws its own **Legal** link, so ours has to go
        // away rather than keep crediting a provider that is no longer drawn.
        //
        // And the camera pill above it has to close the gap the line leaves
        // behind, which is the one thing here that is not Auto Layout's own
        // doing — see ``MapView/Coordinator/applyCreditLineClearance()``.
        #if os(iOS)
        coordinator.attributionView?.update(with: tileSource?.attribution)
        coordinator.applyCreditLineClearance()
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
        let glass = makeTrackingButton(for: mapView, coordinator)
        mapView.addSubview(glass)
        coordinator.trackingButton = glass

        let initialTrackingButtonY: CGFloat = 400
        // The bottom is pinned to the map's top (full-screen space) so its constant
        // is a global Y that the sheet observation drives as the sheet is dragged.
        let bottom = glass.bottomAnchor.constraint(equalTo: mapView.topAnchor, constant: initialTrackingButtonY)
        coordinator.trackingBottomConstraint = bottom

        let guide = makeControlsGuide(in: mapView, coordinator)
        NSLayoutConstraint.activate([
            glass.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -Self.controlInset),
            bottom,
        ])

        // The credit line first: the camera pill is constrained against it
        // rather than against a constant of its own, so it has to exist by the
        // time the pill's constraints are made.
        addAttribution(to: mapView, coordinator, alignedTo: guide)
        addPhotoControls(to: mapView, coordinator, alignedTo: guide)
        addTrailDraftControls(to: mapView, coordinator, alignedTo: guide)
        addAreaSearchControl(to: mapView, coordinator, alignedTo: guide)
        // The maker's own, in the same strip. Only one of the two is ever
        // visible — see `MapTrailPointSearchControl.swift`.
        addTrailPointSearchControl(to: mapView, coordinator, alignedTo: guide)
        // Replaces the placeholders above with real positions as soon as the
        // map has a height to measure against.
        coordinator.applySheetTop(on: mapView)
        #endif
    }

    #if os(iOS)

    /// The credit line, on the leading edge just above the sheet, riding it
    /// exactly as the "my location" button and the camera pill do. It stays on
    /// the map rather than moving into the sheet, as the providers' terms
    /// require. See ``MapAttributionView``.
    ///
    /// The bottom-most of the three things on this edge, and the one the
    /// others are measured from: the camera pill hangs off its top edge — see
    /// ``addPhotoControls(to:_:alignedTo:)`` — so the column is built by Auto
    /// Layout rather than by arithmetic that would have to be redone every
    /// time the line wrapped or the reader's text size moved.
    ///
    /// Its bottom is the same driven Y the tracking button's is, written by
    /// ``MapView/Coordinator/applySheetTop(on:)``, which is what makes the
    /// notice and the controls one row rather than three views that happen to
    /// agree. It takes that call's fade as well: past the middle detent the
    /// sheet is over this part of the map, and a credit drawn behind a sheet
    /// is not a credit anybody is reading.
    private func addAttribution(
        to mapView: MKMapView,
        _ coordinator: Coordinator,
        alignedTo guide: UILayoutGuide
    ) {
        let attribution = MapAttributionView()
        attribution.translatesAutoresizingMaskIntoConstraints = false
        mapView.addSubview(attribution)
        coordinator.attributionView = attribution

        let initialAttributionY: CGFloat = 400
        // Against the map's own top edge, like the two controls: the constant
        // is a global Y, and the map ignores the safe area, so it is the same
        // space ``SheetMetrics`` reports its own in. A placeholder until
        // `applySheetTop(on:)` has a height to measure against.
        let bottom = attribution.bottomAnchor.constraint(
            equalTo: mapView.topAnchor,
            constant: initialAttributionY
        )
        coordinator.attributionBottomConstraint = bottom

        NSLayoutConstraint.activate([
            bottom,
            // The same inset the camera pill takes, so the notice and the
            // control above it share an edge. Against the guide rather than
            // the map, which are the same thing in portrait and are not in
            // landscape, where the map's edge is under the notch and the side
            // panel takes this edge. A credit the reader cannot see is not a
            // credit.
            attribution.leadingAnchor.constraint(
                equalTo: guide.leadingAnchor,
                constant: Self.controlInset
            ),
            // A ceiling rather than a width: the line is as wide as its
            // credits need and no wider, but a provider that names three
            // parties must wrap inside the map rather than run off it.
            attribution.trailingAnchor.constraint(
                lessThanOrEqualTo: guide.trailingAnchor,
                constant: -Self.controlInset
            ),
        ])
        attribution.update(with: tileSource?.attribution)
    }
    #endif

    #if os(iOS)
    /// The camera pill, on the leading edge directly above the credit line and
    /// sharing its edge, so the two read as one stack rather than as a control
    /// and a notice that happen to be near each other.
    ///
    /// Constrained against the line rather than given a driven constant of its
    /// own, which is what keeps the gap between them exactly
    /// ``creditLineSpacing`` through everything that changes the line's height:
    /// a provider that names three parties and wraps onto a second row, and the
    /// reader's own text size. The line's bottom is the one number the sheet
    /// drives — see ``MapView/Coordinator/applySheetTop(on:)`` — and this rides
    /// it for free.
    ///
    /// The second constraint is the case where there is nothing to credit: the
    /// system base map, whose one credit MapKit draws its own **Legal** link
    /// for. A hidden view still takes part in Auto Layout, so hanging off its
    /// top would park the pill a credit line's height above the sheet with
    /// nothing drawn in between. Swapping to the line's *bottom* edge closes
    /// that gap exactly, and ``MapView/Coordinator/applyCreditLineClearance()``
    /// is what picks between the two.
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

        guard let attribution = coordinator.attributionView else { return }
        coordinator.photoControlsAboveCreditLine = controls.bottomAnchor.constraint(
            equalTo: attribution.topAnchor,
            constant: -Self.creditLineSpacing
        )
        coordinator.photoControlsWithoutCreditLine = controls.bottomAnchor.constraint(
            equalTo: attribution.bottomAnchor
        )

        NSLayoutConstraint.activate([
            controls.leadingAnchor.constraint(
                equalTo: guide.leadingAnchor,
                constant: Self.controlInset
            ),
        ])
        coordinator.applyCreditLineClearance()
    }
    #endif

    /// How far the map's floating controls sit in from its safe area.
    ///
    /// Spent on MapKit's own compass and scale as well — see
    /// ``applyBuiltInControlMargins(to:)`` — so the controls this file adds
    /// and the ones the framework draws read as one set rather than two.
    /// Internal for that call and for the test that measures it.
    static let controlInset: CGFloat = 12

    #if os(iOS)
    /// The gap between the camera pill and the credit line under it.
    ///
    /// Much smaller than the inset above, on purpose: this is the space
    /// *inside* one stack of leading-edge chrome, not the space between that
    /// chrome and the edge of the map.
    static let creditLineSpacing: CGFloat = 4
    #endif

    /// Draws the current route (if any) and fits the map to it. No-op while the
    /// same route is already shown, so unrelated view updates don't re-zoom.
    private func updateRoute(_ mapView: MKMapView, _ coordinator: Coordinator) {
        guard coordinator.routeID != route?.id else { return }
        coordinator.routeID = route?.id

        if let existing = coordinator.routeOverlay {
            mapView.removeOverlay(existing)
            coordinator.routeOverlay = nil
            // With the line, because a tap hit-tests these points and a route
            // that is no longer drawn must not still be tappable.
            coordinator.routeCoordinates = []
        }
        if !coordinator.inferredRouteOverlays.isEmpty {
            mapView.removeOverlays(coordinator.inferredRouteOverlays)
            coordinator.inferredRouteOverlays = []
        }
        if !coordinator.pausedRouteOverlays.isEmpty {
            mapView.removeOverlays(coordinator.pausedRouteOverlays)
            coordinator.pausedRouteOverlays = []
        }

        guard let route, route.coordinates.count > 1 else { return }

        // The line's colour and width aren't read here: `observeRouteStyle`
        // keeps `coordinator.routeTint`/`routeWidth` current, and `rendererFor`
        // takes the new polyline's style from those.
        let polyline = MKPolyline(coordinates: route.coordinates, count: route.coordinates.count)
        coordinator.routeOverlay = polyline
        // Kept alongside so a tap can be answered without reading them back
        // out of MapKit — see ``MapView/Coordinator/routeCoordinates``.
        coordinator.routeCoordinates = route.coordinates
        if let tileOverlay = coordinator.tileOverlay {
            // Above the shared hikes' lines when any are drawn, rather than
            // above the tiles they are anchored on: both sit in this level,
            // and naming the tile overlay here would slide this line
            // underneath theirs. See `MapCommunityRoutes.swift`, which keeps
            // the topmost of them last.
            let base: any MKOverlay = coordinator.communityRoutes.last?.polyline ?? tileOverlay
            mapView.insertOverlay(polyline, above: base)
        } else {
            mapView.addOverlay(polyline, level: .aboveLabels)
        }
        addInferredOverlays(route, on: mapView, coordinator, above: polyline)
        // Above the inferred stretches rather than above the line, because
        // `insertOverlay(_:above:)` inserts *just* above what it is given: two
        // calls naming the same base would stack the second one under the
        // first.
        addPausedOverlays(
            route,
            on: mapView,
            coordinator,
            above: coordinator.inferredRouteOverlays.last ?? polyline
        )

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

    /// Overlays the stretches the recording was paused across, on top of the
    /// solid line they belong to.
    ///
    /// Drawn over rather than instead of the route for the same reasons as the
    /// inferred stretches: the geometry the map fits and the chart scrubs
    /// against stays one continuous line, and the dots read as a qualification
    /// of that line. A pause and a lost signal can both fall on the same walk,
    /// and this goes on last so a stretch that is somehow both shows the pause
    /// — the stronger statement, since it says why nothing was recorded.
    private func addPausedOverlays(
        _ route: DisplayedRoute,
        on mapView: MKMapView,
        _ coordinator: Coordinator,
        above base: MKPolyline
    ) {
        guard !route.pausedSegments.isEmpty else { return }
        let overlays = route.pausedSegments.map { segment in
            MKPolyline(coordinates: segment, count: segment.count)
        }
        coordinator.pausedRouteOverlays = overlays
        for overlay in overlays {
            mapView.insertOverlay(overlay, above: base)
        }
    }

    /// Keeps the map's own controls clear of ``MapSidePanel``.
    ///
    /// The guide the controls hang off is pulled in from the leading edge by
    /// the panel's width, which moves the credit line and the camera pill —
    /// both aligned to it — out from behind the panel in one write, and leaves
    /// the map itself full-bleed underneath. The tracking button is on the
    /// trailing edge and does not move; nothing is there.
    ///
    /// Directional anchors already mirror the inset in a right-to-left layout.
    /// Written only when it changes, since a constraint write requests layout.
    private func applySidePanelInset(_ coordinator: Coordinator) {
        #if canImport(UIKit)
        coordinator.sidePanelInset = sidePanelInset
        // These anchors are already directional: positive leading moves into
        // the safe area in either direction. Mirroring again moves the wrong edge.
        if coordinator.controlsLeadingConstraint?.constant != sidePanelInset {
            coordinator.controlsLeadingConstraint?.constant = sidePanelInset
        }
        #endif
    }

    #if os(iOS)
    /// Where MapKit's *own* controls — the compass and the scale — are allowed
    /// to sit.
    ///
    /// They are not subviews this file adds and cannot be constrained; MapKit
    /// lays them out against the map's layout margins, which default to the
    /// system's 8 points on a view that fills the window. That put the scale
    /// hard against the top edge, and in landscape behind ``MapSidePanel`` as
    /// well — where the panel starts at the leading edge the scale is drawn on.
    ///
    /// The scale is the one control here with no second chance to be noticed:
    /// `showsScale` is adaptive, so it appears only while the hiker is
    /// pinching and fades again, and a reference distance that is only ever
    /// drawn under a panel is a reference distance the map does not have.
    ///
    /// `insetsLayoutMarginsFromSafeArea` stays on, so what is set here is a
    /// floor rather than a position: the effective margin on each edge is this
    /// or the device's own safe area, whichever is larger. That is why the top
    /// is a small gap rather than a guess at a notch — portrait keeps the safe
    /// area it already had, and landscape, where the top inset is nothing,
    /// gains the gap.
    ///
    /// The leading margin carries the panel for the same reason
    /// ``makeControlsGuide(in:_:)`` does. It is spent without the safe area
    /// added on top, unlike ``MapView/Coordinator/fit(_:on:animated:)``, because
    /// this one is a floor and the panel's width is already wider than any
    /// device's side inset.
    private func applyBuiltInControlMargins(to mapView: MKMapView) {
        let margins = NSDirectionalEdgeInsets(
            top: Self.controlInset,
            leading: sidePanelInset + Self.controlInset,
            bottom: Self.controlInset,
            trailing: Self.controlInset
        )
        // Written only when it changes: a margin write invalidates the map's
        // layout, and this runs from `update` — the one view here that cannot
        // afford a free layout pass.
        guard mapView.directionalLayoutMargins != margins else { return }
        mapView.directionalLayoutMargins = margins
    }
    #endif

    func update(_ mapView: MKMapView, _ coordinator: Coordinator) {
        // Fires on every SwiftUI-driven update pass, whether or not any of the
        // steps below actually change anything — compare its rate against the
        // "Rebuilt"/"Centered"/"Restyled" marks to see how much of that is
        // real work vs. free no-ops.
        applySidePanelInset(coordinator)
        #if os(iOS)
        applyBuiltInControlMargins(to: mapView)
        #endif
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

// MARK: - When an update is worth running

// A same-file extension rather than more of the struct above, for the reason
// `OpenHikesView`'s own relocations take one: `type_body_length` is a limit on
// a body and an extension is not one. Nothing about this comparison belongs
// anywhere else.
extension MapView {
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
            && lhs.walkHighlight === rhs.walkHighlight
            && lhs.recordingTrace === rhs.recordingTrace
            && lhs.sheetMetrics === rhs.sheetMetrics
            && lhs.tileSource == rhs.tileSource
            && lhs.mapController === rhs.mapController
            && lhs.drawnRouteTap === rhs.drawnRouteTap
            && lhs.locationAccessPrompt === rhs.locationAccessPrompt
            && lhs.locationManager === rhs.locationManager
            && lhs.photoCapture === rhs.photoCapture
            && lhs.photoPins === rhs.photoPins
            && lhs.placePins === rhs.placePins
            && lhs.trailMaker === rhs.trailMaker
            && lhs.community === rhs.community
            && lhs.searchCompleter === rhs.searchCompleter
            && lhs.sidePanelInset == rhs.sidePanelInset
    }
}

#if os(iOS)
private extension MapView {
    /// The safe area the map's own controls are aligned to, which is the
    /// device's own until a ``MapSidePanel`` takes the leading edge.
    ///
    /// The leading constraint is kept so the panel's width can be spent on
    /// it later; the other three edges stay against the device's safe area.
    private func makeControlsGuide(in mapView: MKMapView, _ coordinator: Coordinator) -> UILayoutGuide {
        let safeArea = mapView.safeAreaLayoutGuide
        let controls = UILayoutGuide()
        mapView.addLayoutGuide(controls)

        let leading = controls.leadingAnchor.constraint(equalTo: safeArea.leadingAnchor)
        let trailing = controls.trailingAnchor.constraint(equalTo: safeArea.trailingAnchor)
        coordinator.controlsLeadingConstraint = leading

        NSLayoutConstraint.activate([
            leading,
            trailing,
            controls.topAnchor.constraint(equalTo: safeArea.topAnchor),
            controls.bottomAnchor.constraint(equalTo: safeArea.bottomAnchor),
        ])
        return controls
    }
}
#endif
