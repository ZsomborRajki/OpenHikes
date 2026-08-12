//
//  MapCoordinatorTests.swift
//  OpenTrailsTests
//
//  `MapView.Coordinator` is where this app's central performance idea actually
//  lands: high-frequency state (a GPS fix, an elevation-chart scrub, a sheet
//  drag, a colour well) is applied to a real `MKMapView` imperatively, so it
//  never travels through SwiftUI. `RenderIsolationTests` pins the *observation*
//  half of that — who gets notified, and how often. This pins the other half:
//  what the coordinator does to the map when it is.
//
//  Driven against a real `MKMapView` rather than a protocol, because the
//  behaviour worth checking is MapKit's: which overlays are installed and in
//  what order, whether a redraw rebuilds them or reuses them, what the
//  renderer for each one is, and where the tracking button ends up.
//

import CoreLocation
import Foundation
import MapKit
import SwiftUI
import Testing
@testable import OpenTrails

@MainActor
@Suite("Map coordinator")
struct MapCoordinatorTests {
    private let highlight = RouteHighlight()
    private let recordingTrace = RecordingTrace()
    private let sheetMetrics = SheetMetrics()
    private let mapController = MapController()
    private let routeStyle = RouteStyle()
    /// Driven by a clock the test owns: `LocationManager` publishes at most
    /// once a second, so whether a second fix reaches the map would otherwise
    /// depend on how long the preceding assertions took.
    private let clock = TestClock()
    private let locationManager: LocationManager

    init() {
        locationManager = LocationManager(clock: clock.read)
    }

    private static let osm = ActiveTileSource(
        providerID: "osm_test",
        urlTemplate: "https://tiles.example.invalid/{z}/{x}/{y}.png",
        maximumZ: 19
    )
    private static let other = ActiveTileSource(
        providerID: "other_test",
        urlTemplate: "https://other.example.invalid/{z}/{x}/{y}.png",
        maximumZ: 17
    )

    private func mapView(
        route: DisplayedRoute? = nil,
        tileSource: ActiveTileSource = osm
    ) -> MapView {
        MapView(
            locationManager: locationManager,
            route: route,
            routeStyle: routeStyle,
            highlight: highlight,
            recordingTrace: recordingTrace,
            sheetMetrics: sheetMetrics,
            tileSource: tileSource,
            mapController: mapController
        )
    }

    private static func route(_ id: UUID = UUID(), coordinates: [RouteCoordinate] = Fixture.ridgeRoute) -> DisplayedRoute {
        DisplayedRoute(id: id, coordinates: Fixture.coordinates(coordinates))
    }

    /// A map with a size, so the constraint maths and the visible rect mean
    /// something. Views under test are never in a window.
    private func makeMap(_ view: MapView, _ coordinator: MapView.Coordinator) -> MKMapView {
        let map = view.makeMapView(coordinator)
        map.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        map.layoutIfNeeded()
        return map
    }

    /// Hands MapKit's own machinery back before the test ends.
    ///
    /// A map built here is switched on: it is tracking the user's location, it
    /// has a tile overlay with loads in flight against the app's real cache,
    /// and `MKMapView.delegate` is a weak reference to a coordinator that is
    /// about to deallocate. Left alone, each test abandons all of that and the
    /// next one starts another.
    ///
    /// Called from a `defer` in each test rather than from a suite `deinit`:
    /// a suite instance is not guaranteed to be released on the main actor,
    /// and every property here is main-actor isolated.
    private func detach(_ map: MKMapView) {
        map.delegate = nil
        map.showsUserLocation = false
        map.removeOverlays(map.overlays)
        map.removeAnnotations(map.annotations)
    }

    /// Lets the `Task { @MainActor in … }` hop each observation re-registers
    /// through actually run — the same hop the app pays for a scrub or a drag.
    private func settle() async {
        for _ in 0..<8 { await Task.yield() }
    }

    // MARK: Registration

    /// Everything `makeMapView` is responsible for wiring, checked on the map
    /// itself rather than on the code that was supposed to wire it.
    @Test("building the map registers the coordinator and installs the tiles")
    func buildingRegistersEverything() throws {
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(), coordinator)
        defer { detach(map) }

        #expect(map.delegate === coordinator, "no delegate means no renderers and no overlays drawn")
        #expect(map.showsUserLocation)

        let overlay = try #require(coordinator.tileOverlay)
        #expect(map.overlays.contains { $0 === overlay }, "the tile overlay is the base map")
        #expect(overlay.providerID == Self.osm.providerID)
        #expect(overlay.canReplaceMapContent, "otherwise Apple's map is drawn underneath")
        #expect(overlay.maximumZ == Self.osm.maximumZ)
        #expect(coordinator.tileSourceKey != nil, "the key is what makes a rebuild a no-op")

        #if os(iOS)
        #expect(coordinator.trackingBottomConstraint != nil, "the sheet has nothing to push against otherwise")
        #endif
    }

    // MARK: Overlay churn

    /// `update` runs on every SwiftUI pass that reaches the map, including the
    /// many that changed nothing. Rebuilding the tile overlay there would throw
    /// away MapKit's tile state — and with it every tile on screen — at a rate
    /// set by the rest of the app.
    @Test("an update that changes nothing keeps the same tile overlay")
    func repeatedUpdatesReuseTheTileOverlay() {
        let coordinator = MapView.Coordinator()
        let view = mapView()
        let map = makeMap(view, coordinator)
        defer { detach(map) }
        let installed = coordinator.tileOverlay

        view.update(map, coordinator)
        view.update(map, coordinator)

        #expect(coordinator.tileOverlay === installed, "the same source must not rebuild the overlay")
        #expect(map.overlays.filter { $0 is TileOverlay }.count == 1)
    }

    /// Switching provider in Settings must swap the overlay — and take the old
    /// one out, or the two draw on top of each other.
    @Test("changing provider replaces the tile overlay rather than stacking it")
    func changingProviderSwapsTheOverlay() throws {
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(), coordinator)
        defer { detach(map) }
        let first = try #require(coordinator.tileOverlay)

        mapView(tileSource: Self.other).update(map, coordinator)

        let second = try #require(coordinator.tileOverlay)
        #expect(second !== first)
        #expect(second.providerID == Self.other.providerID)
        #expect(map.overlays.filter { $0 is TileOverlay }.count == 1, "the previous provider must be removed")
        #expect(!map.overlays.contains { $0 === first })
    }

    /// The same guard for the route line, which is the expensive one: an
    /// `MKPolyline` over a five-hour track is rebuilt from every coordinate.
    @Test("an update that changes nothing keeps the same route overlay")
    func repeatedUpdatesReuseTheRouteOverlay() throws {
        let coordinator = MapView.Coordinator()
        let view = mapView(route: Self.route())
        let map = makeMap(view, coordinator)
        defer { detach(map) }

        view.update(map, coordinator)
        let drawn = try #require(coordinator.routeOverlay)
        view.update(map, coordinator)

        #expect(coordinator.routeOverlay === drawn, "same selection, same line")
        #expect(map.overlays.filter { $0 is MKPolyline }.count == 1)
    }

    @Test("selecting a different hike replaces the route overlay")
    func newRouteReplacesTheOverlay() throws {
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(), coordinator)
        defer { detach(map) }

        mapView(route: Self.route()).update(map, coordinator)
        let first = try #require(coordinator.routeOverlay)

        mapView(route: Self.route(coordinates: Fixture.loopRoute)).update(map, coordinator)

        let second = try #require(coordinator.routeOverlay)
        #expect(second !== first)
        #expect(map.overlays.filter { $0 is MKPolyline }.count == 1, "the previous trail must be removed")
    }

    @Test("deselecting removes the route line")
    func clearingRouteRemovesTheOverlay() {
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(route: Self.route()), coordinator)
        defer { detach(map) }

        mapView(route: nil).update(map, coordinator)

        #expect(coordinator.routeOverlay == nil)
        #expect(!map.overlays.contains { $0 is MKPolyline })
    }

    /// A one-point "route" has no line to draw, and `MKPolyline` with a single
    /// coordinate is a degenerate overlay MapKit still asks for a renderer for.
    @Test("a hike with fewer than two points draws no line")
    func degenerateRouteDrawsNothing() {
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(), coordinator)
        defer { detach(map) }

        let single = DisplayedRoute(id: UUID(), coordinates: [CLLocationCoordinate2D(latitude: 47.63, longitude: 12.86)])
        mapView(route: single).update(map, coordinator)

        #expect(coordinator.routeOverlay == nil)
        #expect(!map.overlays.contains { $0 is MKPolyline })
    }

    // MARK: Renderers

    @Test("each overlay gets the renderer it needs")
    func renderersMatchTheirOverlays() throws {
        let coordinator = MapView.Coordinator()
        let view = mapView(route: Self.route())
        let map = makeMap(view, coordinator)
        defer { detach(map) }
        view.update(map, coordinator)

        let tiles = try #require(coordinator.tileOverlay)
        #expect(coordinator.mapView(map, rendererFor: tiles) is CachingTileOverlayRenderer)

        let line = try #require(coordinator.routeOverlay)
        let renderer = try #require(coordinator.mapView(map, rendererFor: line) as? DirectionalPolylineRenderer)
        #expect(renderer.lineWidth == CGFloat(coordinator.routeWidth), "the line is drawn in the current style")
        #expect(coordinator.routeRenderer === renderer, "kept, so a colour drag can recolour it in place")
    }

    @Test("a live recording rebuilds only its bounded tail")
    func recordingTraceUsesChunkedOverlays() async throws {
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(), coordinator)
        defer { detach(map) }

        for step in 0..<RecordingTrace.chunkSize {
            recordingTrace.append(
                CLLocationCoordinate2D(
                    latitude: 47.63 + Double(step) * 0.00001,
                    longitude: 12.86
                )
            )
        }
        await settle()

        #expect(coordinator.recordingChunkOverlays.count == 1)
        let committed = try #require(coordinator.recordingChunkOverlays.first)
        #expect(committed.pointCount == RecordingTrace.chunkSize)
        #expect(coordinator.recordingTailOverlay == nil)

        recordingTrace.append(
            CLLocationCoordinate2D(latitude: 47.64, longitude: 12.86)
        )
        await settle()

        #expect(coordinator.recordingChunkOverlays.first === committed)
        let tail = try #require(coordinator.recordingTailOverlay)
        #expect(tail.pointCount == 2)
        #expect(
            coordinator.mapView(map, rendererFor: tail)
                is MKPolylineRenderer
        )
        #expect(
            !(coordinator.mapView(map, rendererFor: tail)
                is DirectionalPolylineRenderer)
        )
    }

    @Test("an ambiguous review leg is rendered as a distinct overlay")
    func ambiguityReviewUsesADistinctOverlay() async throws {
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(), coordinator)
        defer { detach(map) }
        let route = [
            CLLocationCoordinate2D(latitude: 47.63, longitude: 12.86),
            CLLocationCoordinate2D(latitude: 47.631, longitude: 12.861),
            CLLocationCoordinate2D(latitude: 47.632, longitude: 12.862)
        ]
        recordingTrace.showReview(
            route: route,
            highlightedSegment: Array(route.suffix(2))
        )
        await settle()

        let overlay = try #require(coordinator.recordingReviewOverlay)
        let renderer = try #require(
            coordinator.mapView(map, rendererFor: overlay)
                as? MKPolylineRenderer
        )
        #expect(renderer.lineWidth == 7)
        #expect(renderer.lineDashPattern == [3, 5])
        #expect(coordinator.recordingTailOverlay != nil)
    }

    // MARK: Route style

    /// A colour well and a width slider are dragged, so their writes arrive at
    /// touch frequency. They reach the live renderer without rebuilding the
    /// overlay — rebuilding one per frame is what this arrangement exists to
    /// avoid.
    @Test("a style change restyles the line in place")
    func styleChangeReusesTheRenderer() async throws {
        let coordinator = MapView.Coordinator()
        let view = mapView(route: Self.route())
        let map = makeMap(view, coordinator)
        defer { detach(map) }
        view.update(map, coordinator)

        let line = try #require(coordinator.routeOverlay)
        let renderer = try #require(coordinator.mapView(map, rendererFor: line) as? DirectionalPolylineRenderer)

        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context) {
            $0.tintHex = "#FF0000FF"
            $0.routeWidth = 9
        }
        routeStyle.follow(hike)
        await settle()

        #expect(coordinator.routeWidth == 9)
        #expect(renderer.lineWidth == 9, "the drawn line, not just the coordinator's copy of the number")
        #expect(coordinator.routeOverlay === line, "restyling must not rebuild the line")
    }

    // MARK: Recentering

    /// The map centres on the user's first fix — once. A second fix a second
    /// later must not drag the map back while they're panning it.
    @Test("the first fix centres the map, and only the first")
    func firstFixCentresOnce() async {
        let coordinator = MapView.Coordinator()
        let view = mapView()
        let map = makeMap(view, coordinator)
        defer { detach(map) }
        view.update(map, coordinator)

        locationManager.locationManager(
            CLLocationManager(),
            didUpdateLocations: [CLLocation(latitude: 47.6300, longitude: 12.8600)]
        )
        await settle()
        #expect(coordinator.hasCentered)
        let centred = map.region.center.latitude

        // Past the publish throttle, so the map really is offered this one.
        clock.advance(by: 1.1)
        locationManager.locationManager(
            CLLocationManager(),
            didUpdateLocations: [CLLocation(latitude: 47.6400, longitude: 12.8600)]
        )
        await settle()

        #expect(locationManager.coordinate?.latitude == 47.6400, "precondition: the second fix was published")
        #expect(map.region.center.latitude == centred, "a later fix must not drag the map back")
    }

    /// A selected route owns the viewport. Centring on the user as well would
    /// yank the map off the trail the moment a fix arrives.
    @Test("a fix doesn't recentre while a route is selected")
    func routeOwnsTheViewport() async {
        let coordinator = MapView.Coordinator()
        let view = mapView(route: Self.route())
        let map = makeMap(view, coordinator)
        defer { detach(map) }
        view.update(map, coordinator)

        locationManager.locationManager(
            CLLocationManager(),
            didUpdateLocations: [CLLocation(latitude: 47.6300, longitude: 12.8600)]
        )
        await settle()

        #expect(!coordinator.hasCentered, "the route decides what's on screen")
    }

    /// The Zoom button, and the initial draw, both go through this: the whole
    /// trail has to end up inside the visible rect.
    @Test("fitting the route puts all of it on screen")
    func fitContainsTheWholeRoute() throws {
        let coordinator = MapView.Coordinator()
        let view = mapView(route: Self.route())
        let map = makeMap(view, coordinator)
        defer { detach(map) }
        view.update(map, coordinator)

        coordinator.fitToCurrentRoute(map, animated: false)

        let polyline = try #require(coordinator.routeOverlay)
        #expect(map.visibleMapRect.contains(polyline.boundingMapRect.origin))
        #expect(
            map.visibleMapRect.intersects(polyline.boundingMapRect),
            "the trail is what the map was asked to frame"
        )
    }

    // MARK: Sheet insets

    /// The "my location" button rides just above the sheet's top edge as it is
    /// dragged, at touch frequency, without a SwiftUI pass in between.
    @Test("the tracking button follows the sheet's top edge")
    func trackingButtonFollowsTheSheet() async throws {
        #if os(iOS)
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(), coordinator)
        defer { detach(map) }
        let constraint = try #require(coordinator.trackingBottomConstraint)
        let spacing: CGFloat = 16

        sheetMetrics.topY = 700
        coordinator.applySheetTop(on: map)
        #expect(constraint.constant == 700 - spacing)

        // A sheet dragged nearly to the top: the button stops at the vertical
        // midpoint rather than climbing into the status bar.
        sheetMetrics.topY = 80
        coordinator.applySheetTop(on: map)
        #expect(constraint.constant == map.bounds.height * 0.5 - spacing)
        #endif
    }

    /// Observed rather than passed in, so a drag never reaches SwiftUI.
    @Test("a sheet drag moves the button without an update pass")
    func sheetDragIsObserved() async throws {
        #if os(iOS)
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(), coordinator)
        defer { detach(map) }
        let constraint = try #require(coordinator.trackingBottomConstraint)
        let spacing: CGFloat = 16

        sheetMetrics.topY = 640
        await settle()

        #expect(constraint.constant == 640 - spacing, "no `update` call in between")
        #endif
    }

    // MARK: Highlight

    /// Scrubbing the elevation chart moves one annotation. Adding and removing
    /// it per sample would churn MapKit's annotation views at drag frequency.
    @Test("scrubbing moves one annotation rather than replacing it")
    func highlightMovesInPlace() async throws {
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(route: Self.route()), coordinator)
        defer { detach(map) }

        highlight.move(to: CLLocationCoordinate2D(latitude: 37.3320, longitude: -122.0300))
        await settle()
        let annotation = try #require(coordinator.highlightAnnotation)
        #expect(map.annotations.contains { $0 === annotation })

        highlight.move(to: CLLocationCoordinate2D(latitude: 37.3360, longitude: -122.0300))
        await settle()
        #expect(coordinator.highlightAnnotation === annotation, "the same dot, moved")
        #expect(abs(annotation.coordinate.latitude - 37.3360) < 1e-9)
        #expect(map.annotations.filter { $0 is MKPointAnnotation }.count == 1)
    }

    @Test("ending a scrub removes the dot")
    func clearingHighlightRemovesTheAnnotation() async throws {
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(route: Self.route()), coordinator)
        defer { detach(map) }

        highlight.move(to: CLLocationCoordinate2D(latitude: 37.3320, longitude: -122.0300))
        await settle()
        try #require(coordinator.highlightAnnotation != nil)

        highlight.move(to: nil)
        await settle()

        #expect(coordinator.highlightAnnotation == nil)
        #expect(!map.annotations.contains { $0 is MKPointAnnotation })
    }

    /// The dot is drawn in the route's tint, so a colour change has to reach
    /// the annotation view as well as the line.
    @Test("the highlight dot is drawn in the current route tint")
    func highlightUsesTheRouteTint() async throws {
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(route: Self.route()), coordinator)
        defer { detach(map) }
        coordinator.routeTint = .red

        highlight.move(to: CLLocationCoordinate2D(latitude: 37.3320, longitude: -122.0300))
        await settle()
        let annotation = try #require(coordinator.highlightAnnotation)

        let view = try #require(coordinator.mapView(map, viewFor: annotation))
        #expect(view.canShowCallout == false)
        #if canImport(UIKit)
        let expected = UIColor(Color.red).withAlphaComponent(1).cgColor
        #expect(view.layer.backgroundColor == expected)
        #endif
    }

    /// MapKit's own callout for the blue dot pulls the "Me" contact's photo out
    /// of Contacts. Suppressed by deselecting it the moment it's selected.
    @Test("the user-location dot gets no annotation view and no callout")
    func userLocationIsLeftToMapKit() {
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(), coordinator)
        defer { detach(map) }

        #expect(coordinator.mapView(map, viewFor: map.userLocation) == nil, "MapKit draws its own")
    }
}
