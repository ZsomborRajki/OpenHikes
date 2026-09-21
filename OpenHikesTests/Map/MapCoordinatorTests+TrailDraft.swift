//
//  MapCoordinatorTests+TrailDraft.swift
//  OpenHikesTests
//
//  The map's half of the trail maker: the pill, and the canvas.
//
//  Two things are worth pinning here and neither is visible from the maker's
//  own screen.
//
//  **The slot is shared.** The maker's pill takes the place the camera pill
//  occupies, hangs off the same anchors and rides the same sheet-driven row —
//  so what is asserted is not where it sits but that it is never anywhere
//  else, which is the same claim `MapCoordinatorTests+PhotoControls` makes for
//  its neighbour. A second control placed by hand would be only approximately
//  level, and the drift would show at the detents nobody tests by hand.
//
//  **A tap means one thing while the maker is up.** The recognizer on this map
//  answers for the hiker's own line and for every shared hike's; both are
//  suspended while a trail is being drawn, because a tap that put a point down
//  *and* opened somebody's trail would be a tap that did two things. What it
//  does not suspend is the controls over the map: a thumb on the tracking
//  button is not a waypoint. Nor are the maker's own pins controls — they
//  answer no tap, so they hand it back rather than swallowing it.
//

import CoreLocation
import Foundation
import MapKit
@testable import OpenHikes
import Testing

extension MapCoordinatorTests {
    /// `Fixture.ridgeRoute` runs due north near Cupertino along one line of
    /// longitude; these are the numbers that frame it so a screen point
    /// converts to somewhere on it.
    private enum Ridge {
        static let longitude: Double = -122.0300
        /// The middle of the fixture route, so the centre of the map is on it.
        static let latitude: Double = 37.3350
        /// Wide enough that the whole route is on screen at the size
        /// `makeMap` gives, so a screen point means something.
        static let span: Double = 0.05
        static let south: Double = 37.3300
        static let north: Double = 37.3400
        /// Half a metre or so of latitude: close enough that a round trip
        /// through MapKit's projection is the only difference left.
        static let coordinateTolerance: Double = 0.00001
    }

    private static func ridgeRegion() -> MKCoordinateRegion {
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: Ridge.latitude,
                longitude: Ridge.longitude
            ),
            span: MKCoordinateSpan(latitudeDelta: Ridge.span, longitudeDelta: Ridge.span)
        )
    }

    private static func ridgeCoordinate(_ latitude: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: Ridge.longitude)
    }

    /// A pin's frame centred on `point`, at the diameter the maker draws.
    ///
    /// Placed by hand rather than by adding the annotation and waiting: what
    /// is being asserted is what `hitTest` finds under a thumb, and MapKit
    /// makes an annotation's view when it feels like it.
    private static func pinFrame(around point: CGPoint) -> CGRect {
        let diameter: CGFloat = 24
        return CGRect(
            x: point.x - diameter / 2,
            y: point.y - diameter / 2,
            width: diameter,
            height: diameter
        )
    }

    // MARK: The pill

    @Test("there is no maker pill until the sheet says nothing is pushed")
    func trailDraftPillHiddenUntilOffered() throws {
        #if os(iOS)
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(), coordinator)
        defer { detach(map) }
        let pill = try #require(coordinator.trailDraftControls)

        // Hidden as well as transparent: it sits over a map the hiker pans.
        #expect(pill.isHidden)
        #expect(pill.alpha == 0)
        #endif
    }

    /// The map can be built while the sheet already has nothing pushed — a
    /// rotation rebuilds it, and so does a launch straight into landscape — so
    /// the first visibility pass has to happen after the pill exists rather
    /// than before.
    @Test("a maker pill already on offer when the map is built is visible at once")
    func trailDraftPillVisibleOnFirstBuild() throws {
        #if os(iOS)
        trailMaker.setHostScreenPresent(false)

        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(), coordinator)
        defer { detach(map) }
        let pill = try #require(coordinator.trailDraftControls)

        // Synchronous: no availability change follows the build, so nothing
        // arrives later to correct it.
        #expect(!pill.isHidden)
        #expect(pill.alpha == 1)
        #endif
    }

    @Test("the maker pill arrives and goes with the sheet's pushed screen")
    func trailDraftPillFollowsTheSheet() async throws {
        #if os(iOS)
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(), coordinator)
        defer { detach(map) }
        let pill = try #require(coordinator.trailDraftControls)

        trailMaker.setHostScreenPresent(false)
        await settle(until: "the maker pill to appear") { !pill.isHidden }
        #expect(pill.isUserInteractionEnabled)

        trailMaker.setHostScreenPresent(true)
        await settle(until: "the maker pill to leave") { pill.alpha == 0 }
        // Interaction goes at once rather than when the fade lands: a pill on
        // its way out is still a tap target for the whole quarter-second.
        #expect(!pill.isUserInteractionEnabled)
        #endif
    }

    /// The claim nothing in the app enforces directly — two definitions in two
    /// files, offered on opposite signals — asserted on the map where it would
    /// actually show.
    @Test("the maker pill and the camera pill are never both on the map")
    func onePillAtATime() async throws {
        #if os(iOS)
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(), coordinator)
        defer { detach(map) }
        let maker = try #require(coordinator.trailDraftControls)
        let camera = try #require(coordinator.photoControls)

        trailMaker.setHostScreenPresent(false)
        photoCapture.setHostScreenPresent(false)
        await settle(until: "the maker pill to appear") { !maker.isHidden }
        #expect(camera.isHidden)

        // A hike screen pushed, offering a photograph.
        trailMaker.setHostScreenPresent(true)
        photoCapture.setHostScreenPresent(true)
        photoCapture.attach(to: hike) { nil }
        await settle(until: "the camera pill to appear") { !camera.isHidden }
        await settle(until: "the maker pill to leave") { maker.alpha == 0 }
        #expect(!(maker.alpha > 0 && camera.alpha > 0))
        #endif
    }

    @Test("the maker pill rides the sheet exactly as the camera pill does")
    func trailDraftPillSharesTheSlot() throws {
        #if os(iOS)
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(), coordinator)
        defer { detach(map) }
        let camera = try #require(coordinator.photoControls)
        let maker = try #require(coordinator.trailDraftControls)
        map.layoutIfNeeded()

        var offsets: Set<CGFloat> = []
        for topY in stride(from: 120.0, through: map.bounds.height, by: 20) {
            sheetMetrics.topY = topY
            coordinator.applySheetTop(on: map)
            map.setNeedsLayout()
            map.layoutIfNeeded()
            offsets.insert((camera.frame.maxY - maker.frame.maxY).rounded())
        }
        #expect(offsets == [0], "the two pills do not occupy one slot")
        #endif
    }

    // MARK: The canvas

    @Test("a tap on the map puts a point down while the maker is up")
    func tapAddsAWaypoint() throws {
        #if os(iOS)
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(), coordinator)
        defer { detach(map) }
        map.setRegion(Self.ridgeRegion(), animated: false)
        trailMaker.setEditing(true)

        let point = CGPoint(x: map.bounds.midX, y: map.bounds.midY)
        #expect(coordinator.addTrailDraftWaypoint(at: point, in: map))

        let waypoint = try #require(trailMaker.draft.waypoints.first)
        let expected = map.convert(point, toCoordinateFrom: map)
        #expect(abs(waypoint.latitude - expected.latitude) < Ridge.coordinateTolerance)
        #expect(abs(waypoint.longitude - expected.longitude) < Ridge.coordinateTolerance)
        #endif
    }

    @Test("a tap on the map puts nothing down while the maker is closed")
    func tapAddsNothingWhenClosed() {
        #if os(iOS)
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(), coordinator)
        defer { detach(map) }
        map.setRegion(Self.ridgeRegion(), animated: false)

        let point = CGPoint(x: map.bounds.midX, y: map.bounds.midY)
        #expect(!coordinator.addTrailDraftWaypoint(at: point, in: map))
        #expect(trailMaker.draft.isEmpty)
        #endif
    }

    /// The controls over the map keep their claim on a touch. A thumb on the
    /// tracking button, the credit line or the pill that opened this mode must
    /// not leave a waypoint behind it.
    @Test("a tap on a control over the map is not a waypoint")
    func tapOnAControlIsNotAWaypoint() throws {
        #if os(iOS)
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(), coordinator)
        defer { detach(map) }
        map.setRegion(Self.ridgeRegion(), animated: false)
        trailMaker.setEditing(true)
        let button = try #require(coordinator.trackingButton)
        map.layoutIfNeeded()

        let onTheButton = CGPoint(x: button.frame.midX, y: button.frame.midY)
        #expect(!coordinator.addTrailDraftWaypoint(at: onTheButton, in: map))
        #expect(trailMaker.draft.isEmpty)
        #endif
    }

    /// The maker's own pins are not among those controls, and this is the pair
    /// that makes that a distinction rather than a hole. A waypoint pin shows
    /// no callout and answers no tap, so a tap it took would simply vanish —
    /// and with no undo, no drag and no delete in this phase, a hiker drawing
    /// a switchback past a point they already put down could not tell a
    /// swallowed tap from a missed one.
    @Test("a tap on the draft's own pin is still a waypoint")
    func tapOnADraftPinIsAWaypoint() throws {
        #if os(iOS)
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(), coordinator)
        defer { detach(map) }
        map.setRegion(Self.ridgeRegion(), animated: false)
        trailMaker.setEditing(true)
        map.layoutIfNeeded()

        let point = CGPoint(x: map.bounds.midX, y: map.bounds.midY)
        let pin = try #require(
            coordinator.mapView(
                map,
                viewFor: TrailDraftWaypointAnnotation(
                    coordinate: map.convert(point, toCoordinateFrom: map),
                    number: 1
                )
            )
        )
        pin.frame = Self.pinFrame(around: point)
        map.addSubview(pin)

        #expect(coordinator.addTrailDraftWaypoint(at: point, in: map))
        #expect(trailMaker.draft.waypoints.count == 1)
        #endif
    }

    /// The other half of it: a marker that *does* answer a tap still takes it,
    /// which is the rule `addTrailDraftWaypoint(at:in:)` states and the reason
    /// a shared hike's pin still opens its callout while a trail is drawn.
    @Test("a tap on a marker that answers taps is not a waypoint")
    func tapOnAnotherMarkerIsNotAWaypoint() {
        #if os(iOS)
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(), coordinator)
        defer { detach(map) }
        map.setRegion(Self.ridgeRegion(), animated: false)
        trailMaker.setEditing(true)
        map.layoutIfNeeded()

        let point = CGPoint(x: map.bounds.midX, y: map.bounds.midY)
        let marker = MKAnnotationView(
            annotation: MKPointAnnotation(),
            reuseIdentifier: nil
        )
        marker.frame = Self.pinFrame(around: point)
        map.addSubview(marker)

        #expect(!coordinator.addTrailDraftWaypoint(at: point, in: map))
        #expect(trailMaker.draft.isEmpty)
        #endif
    }

    /// The hiker's own line is drawn under the canvas and is normally tappable
    /// — see `MapCoordinatorTests+RouteTap`. While a trail is being drawn it
    /// is not, because a tap here means one thing.
    @Test("the drawn route's own tap is suspended while the maker is up")
    func drawnRouteTapIsSuspended() {
        #if os(iOS)
        let coordinator = MapView.Coordinator()
        let view = mapView(route: Self.route())
        let map = makeMap(view, coordinator)
        defer { detach(map) }
        view.update(map, coordinator)
        map.setRegion(Self.ridgeRegion(), animated: false)

        // The route runs due north through the centre of this region, so the
        // middle of the map is on it. Checked rather than assumed.
        let onTheLine = CGPoint(x: map.bounds.midX, y: map.bounds.midY)
        #expect(
            coordinator.isTapOnDrawnRoute(at: onTheLine, in: map),
            "the fixture is not under the point this test taps"
        )

        trailMaker.setEditing(true)
        #expect(coordinator.addTrailDraftWaypoint(at: onTheLine, in: map))
        #expect(trailMaker.draft.waypoints.count == 1)
        #endif
    }

    // MARK: The line and the pins

    @Test("the draft is drawn while the maker is up and taken down when it goes")
    func draftIsDrawnWhileEditing() async {
        #if os(iOS)
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(), coordinator)
        defer { detach(map) }
        map.setRegion(Self.ridgeRegion(), animated: false)
        trailMaker.setEditing(true)

        trailMaker.appendWaypoint(at: Self.ridgeCoordinate(Ridge.south))
        trailMaker.appendWaypoint(at: Self.ridgeCoordinate(Ridge.north))
        await settle(until: "the draft's line to be drawn") {
            !coordinator.trailDraftOverlays.isEmpty
        }
        #expect(coordinator.trailDraftAnnotations.count == 2)
        #expect(coordinator.trailDraftAnnotations.map(\.number) == [1, 2])
        #expect(map.annotations.contains { $0 is TrailDraftWaypointAnnotation })

        trailMaker.setEditing(false)
        await settle(until: "the draft's line to be taken down") {
            coordinator.trailDraftOverlays.isEmpty
        }
        #expect(coordinator.trailDraftAnnotations.isEmpty)
        #expect(!map.annotations.contains { $0 is TrailDraftWaypointAnnotation })
        #endif
    }

    /// One point is a pin and no line: an `MKPolyline` of a single coordinate
    /// draws nothing and would only be something to remove later.
    @Test("a single point is a pin with no line")
    func onePointDrawsNoLine() async {
        #if os(iOS)
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(), coordinator)
        defer { detach(map) }
        trailMaker.setEditing(true)

        trailMaker.appendWaypoint(at: Self.ridgeCoordinate(Ridge.south))
        await settle(until: "the first pin to be drawn") {
            coordinator.trailDraftAnnotations.count == 1
        }
        #expect(coordinator.trailDraftOverlays.isEmpty)
        #endif
    }

    /// The draft's line is not the hiker's route, so it must not be styled as
    /// one — `rendererFor` asks the draft before every style that describes a
    /// hike's own line.
    @Test("the draft's line gets its own renderer")
    func draftHasItsOwnRenderer() async throws {
        #if os(iOS)
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(), coordinator)
        defer { detach(map) }
        trailMaker.setEditing(true)
        trailMaker.appendWaypoint(at: Self.ridgeCoordinate(Ridge.south))
        trailMaker.appendWaypoint(at: Self.ridgeCoordinate(Ridge.north))
        await settle(until: "the draft's line to be drawn") {
            !coordinator.trailDraftOverlays.isEmpty
        }
        let line = try #require(coordinator.trailDraftOverlays.first)

        let renderer = coordinator.mapView(map, rendererFor: line)

        #expect(renderer is MKPolylineRenderer)
        #expect(!(renderer is DirectionalPolylineRenderer), "that is a hike's own line")
        #endif
    }

    @Test("a waypoint pin draws its number and speaks it")
    func waypointPinIsNumbered() {
        #if os(iOS)
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(), coordinator)
        defer { detach(map) }
        let annotation = TrailDraftWaypointAnnotation(
            coordinate: Self.ridgeCoordinate(Ridge.south),
            number: 3
        )

        let view = coordinator.mapView(map, viewFor: annotation)

        #expect(view != nil)
        #expect(annotation.title == "Point 3")
        #endif
    }
}
