//
//  MapCoordinatorTests.swift
//  OpenHikesTests
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
@testable import OpenHikes
import SwiftUI
import Testing

@Suite("Map coordinator")
struct MapCoordinatorTests {
    private let highlight = RouteHighlight()
    private let recordingTrace = RecordingTrace()
    /// Internal, like `mapController` below, so the tracking-button tests get
    /// their own file — see `MapCoordinatorTests+SheetInsets.swift`.
    let sheetMetrics: SheetMetrics
    /// Internal, like the four helpers below it, so the command observers get
    /// their own file — see `MapCoordinatorTests+Commands.swift`.
    let mapController = MapController()
    private let routeStyle = RouteStyle()
    /// Driven by a clock the test owns: `LocationManager` publishes at most
    /// once a second, and `SheetMetrics` tells a resting sheet from a moving
    /// one by the gap between reports, so both would otherwise depend on how
    /// long the preceding assertions took.
    let clock = TestClock()
    private let locationManager: LocationManager

    init() {
        locationManager = LocationManager(clock: clock.read)
        sheetMetrics = SheetMetrics(clock: clock.read)
    }

    static let osm = ActiveTileSource(
        providerID: "osm_test",
        urlTemplate: "https://tiles.example.invalid/{z}/{x}/{y}.png",
        maximumZ: 19
    )
    private static let other = ActiveTileSource(
        providerID: "other_test",
        urlTemplate: "https://other.example.invalid/{z}/{x}/{y}.png",
        maximumZ: 17
    )

    func mapView(
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

    static func route(
        _ id: UUID = UUID(),
        coordinates: [RouteCoordinate] = Fixture.ridgeRoute
    ) -> DisplayedRoute {
        DisplayedRoute(id: id, coordinates: Fixture.coordinates(coordinates))
    }

    /// A map with a size, so the constraint maths and the visible rect mean
    /// something. Views under test are never in a window.
    func makeMap(_ view: MapView, _ coordinator: MapView.Coordinator) -> MKMapView {
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
    func detach(_ map: MKMapView) {
        map.delegate = nil
        map.showsUserLocation = false
        map.removeOverlays(map.overlays)
        map.removeAnnotations(map.annotations)
    }

    /// Lets the `Task { @MainActor in … }` hop each observation re-registers
    /// through actually run — the same hop the app pays for a scrub or a drag.
    func settle() async {
        for _ in 0..<8 { await Task.yield() }
    }

    // MARK: Registration

    /// Everything `makeMapView` is responsible for wiring, checked on the map
    /// itself rather than on the code that was supposed to wire it.
}

extension MapCoordinatorTests {
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

        let singleCoord = CLLocationCoordinate2D(latitude: 47.63, longitude: 12.86)
        let single = DisplayedRoute(id: UUID(), coordinates: [singleCoord])
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
            CLLocationCoordinate2D(latitude: 47.632, longitude: 12.862),
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
        let hike = Fixture.hike(in: context) { hike in
            hike.tintHex = "#FF0000FF"
            hike.routeWidth = 9
        }
        routeStyle.follow(hike)
        await settle()

        #expect(coordinator.routeWidth == 9)
        #expect(renderer.lineWidth == 9, "the drawn line, not just the coordinator's copy of the number")
        #expect(coordinator.routeOverlay === line, "restyling must not rebuild the line")
    }

    /// The pattern reaches the line the same way the colour does — through the
    /// live renderer. Dashing is an ordinary stroke property, so it has to be
    /// on the renderer itself; the chevrons are the renderer's own business, so
    /// it has to know which pattern it is drawing.
    @Test("a line pattern reaches the live renderer as stroke properties")
    func patternChangeRestylesTheLine() async throws {
        let coordinator = MapView.Coordinator()
        let view = mapView(route: Self.route())
        let map = makeMap(view, coordinator)
        defer { detach(map) }
        view.update(map, coordinator)

        let line = try #require(coordinator.routeOverlay)
        let renderer = try #require(coordinator.mapView(map, rendererFor: line) as? DirectionalPolylineRenderer)
        #expect(renderer.lineDashPattern == nil, "the default line is unbroken")
        #expect(renderer.pattern == .directional)

        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context) { hike in
            hike.routeWidth = 6
            hike.routeLinePattern = .dashed
        }
        routeStyle.follow(hike)
        await settle()

        #expect(coordinator.routePattern == .dashed)
        #expect(renderer.pattern == .dashed)
        #expect(renderer.lineCap == .butt, "round caps would grow each dash into its own gap")
        let dash = try #require(renderer.lineDashPattern).map(\.doubleValue)
        #expect(dash == RouteLinePattern.dashed.dashLengths(forWidth: 6))
        #expect(coordinator.routeOverlay === line, "restyling must not rebuild the line")

        // …and back to an unbroken line: a stale dash pattern left on the
        // renderer would keep drawing gaps the pattern no longer asks for.
        hike.routeLinePattern = .solid
        await settle()
        #expect(renderer.lineDashPattern == nil)
        #expect(renderer.pattern == .solid)
    }

    /// The one pattern that draws no line at all. `MKPolylineRenderer` can't
    /// express that, so it's the subclass that has to skip its own stroke.
    @Test("the arrowheads pattern tells the renderer to skip the line")
    func arrowheadsPatternSkipsTheLine() async throws {
        let coordinator = MapView.Coordinator()
        let view = mapView(route: Self.route())
        let map = makeMap(view, coordinator)
        defer { detach(map) }
        view.update(map, coordinator)

        let line = try #require(coordinator.routeOverlay)
        let renderer = try #require(coordinator.mapView(map, rendererFor: line) as? DirectionalPolylineRenderer)

        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context) { $0.routeLinePattern = .arrowheads }
        routeStyle.follow(hike)
        await settle()

        #expect(renderer.pattern.drawsLine == false)
        #expect(renderer.pattern.drawsChevrons)
    }

    /// A renderer asked for *after* the style changed must be built in it —
    /// selecting a hike and drawing its line are two separate events, and the
    /// pattern arrives with the first.
    @Test("a line drawn after the style changed is drawn in it")
    func rendererAdoptsTheCurrentPattern() async throws {
        let coordinator = MapView.Coordinator()
        let view = mapView(route: Self.route())
        let map = makeMap(view, coordinator)
        defer { detach(map) }

        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context) { hike in
            hike.routeWidth = 5
            hike.routeLinePattern = .dotted
        }
        routeStyle.follow(hike)
        view.update(map, coordinator)
        await settle()

        let line = try #require(coordinator.routeOverlay)
        let renderer = try #require(coordinator.mapView(map, rendererFor: line) as? DirectionalPolylineRenderer)
        #expect(renderer.pattern == .dotted)
        #expect(renderer.lineCap == .round, "a dot is a near-zero dash rounded off by its cap")
        let dash = try #require(renderer.lineDashPattern).map(\.doubleValue)
        #expect(dash == RouteLinePattern.dotted.dashLengths(forWidth: 5))
    }

    /// A recording is always the same red dashed trace: what is being recorded
    /// right now must not depend on a per-hike appearance choice.
    @Test("a per-hike pattern doesn't reach the recording trace")
    func recordingTraceIgnoresThePattern() async throws {
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(), coordinator)
        defer { detach(map) }

        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context) { $0.routeLinePattern = .arrowheads }
        routeStyle.follow(hike)
        await settle()

        recordingTrace.append(CLLocationCoordinate2D(latitude: 47.63, longitude: 12.86))
        recordingTrace.append(CLLocationCoordinate2D(latitude: 47.64, longitude: 12.86))
        await settle()

        let tail = try #require(coordinator.recordingTailOverlay)
        let renderer = try #require(coordinator.mapView(map, rendererFor: tail) as? MKPolylineRenderer)
        #expect(!(renderer is DirectionalPolylineRenderer))
        #expect(renderer.lineWidth == 4)
        #expect(renderer.lineDashPattern == [10, 6])
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
