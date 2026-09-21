//
//  MapCoordinatorTests+TrailDraftEditing.swift
//  OpenHikesTests
//
//  The two edits that can only be made on the map, against a real `MKMapView`.
//
//  Both are arithmetic in screen space and neither is reachable from the
//  maker's screen: a tap on a leg *inserts* rather than appends, and a press
//  on a pin takes hold of it. What decides either is where a thumb landed
//  relative to something MapKit is drawing, so the only way to ask is to put a
//  map on screen, aim it at a fixture and convert a point through it.
//
//  What is deliberately **not** here is the gesture recognizer. Its state and
//  its location are set by the touch system and cannot be driven by a suite —
//  the same split `MapCoordinatorTests+TrailDraft` already makes for the tap —
//  so the handler is four lines that turn a gesture into the calls below, and
//  these are the calls.
//

import CoreLocation
import Foundation
import MapKit
@testable import OpenHikes
import Testing

extension MapCoordinatorTests {
    /// A short line of longitude near Cupertino, framed so a screen point
    /// converts to somewhere on it.
    private enum Drawn {
        static let longitude: Double = -122.0300
        static let centre: Double = 37.3350
        static let span: Double = 0.02
        static let south: Double = 37.3300
        static let north: Double = 37.3400
        /// Off the line, so a point dragged here is unmistakably somewhere
        /// else.
        static let eastLongitude: Double = -122.0200
    }

    private static func drawnRegion() -> MKCoordinateRegion {
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: Drawn.centre,
                longitude: Drawn.longitude
            ),
            span: MKCoordinateSpan(latitudeDelta: Drawn.span, longitudeDelta: Drawn.span)
        )
    }

    private static func drawnCoordinate(
        _ latitude: Double,
        _ longitude: Double = Drawn.longitude
    ) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// A map with the maker open and a two-point line drawn straight down the
    /// middle of it, already on screen.
    private func drawnLine(
        _ coordinator: MapView.Coordinator
    ) async -> MKMapView {
        let map = makeMap(mapView(), coordinator)
        map.setRegion(Self.drawnRegion(), animated: false)
        trailMaker.setEditing(true)
        trailMaker.appendWaypoint(at: Self.drawnCoordinate(Drawn.south))
        trailMaker.appendWaypoint(at: Self.drawnCoordinate(Drawn.north))
        await settle(until: "the drawn line to reach the map") {
            coordinator.trailDraftOverlays.count == 1
                && coordinator.trailDraftAnnotations.count == 2
        }
        return map
    }

    // MARK: Tapping a leg

    /// The tap that makes a drawn trail editable rather than merely
    /// extendable: the point lands *in* the leg, between its two ends, rather
    /// than on the end of the line.
    @Test("a tap on a drawn leg puts a point into it")
    func tapOnALegInserts() async throws {
        #if os(iOS)
        let coordinator = MapView.Coordinator()
        let map = await drawnLine(coordinator)
        defer { detach(map) }

        // The middle of the map is the middle of the line.
        let onTheLeg = CGPoint(x: map.bounds.midX, y: map.bounds.midY)
        #expect(coordinator.trailDraftLegIndex(at: onTheLeg, in: map) == 0)

        #expect(coordinator.addTrailDraftWaypoint(at: onTheLeg, in: map))

        #expect(trailMaker.draft.waypoints.count == 3)
        let inserted = try #require(trailMaker.draft.waypoints.dropFirst().first)
        #expect(inserted.latitude > Drawn.south)
        #expect(inserted.latitude < Drawn.north)
        #endif
    }

    /// And a tap anywhere else still means what it meant: put a point on the
    /// end. The two meanings are one gesture, separated by whether a line the
    /// hiker can see was under the thumb.
    @Test("a tap away from every leg still appends")
    func tapAwayFromALegAppends() {
        #if os(iOS)
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(), coordinator)
        defer { detach(map) }
        map.setRegion(Self.drawnRegion(), animated: false)
        trailMaker.setEditing(true)

        // No line drawn at all, so nothing can be tapped on.
        let anywhere = CGPoint(x: map.bounds.midX, y: map.bounds.midY)
        #expect(coordinator.trailDraftLegIndex(at: anywhere, in: map) == nil)
        #expect(coordinator.addTrailDraftWaypoint(at: anywhere, in: map))
        #expect(trailMaker.draft.waypoints.count == 1)
        #endif
    }

    @Test("a tap well off the line is not a tap on its leg")
    func tapOffTheLine() async {
        #if os(iOS)
        let coordinator = MapView.Coordinator()
        let map = await drawnLine(coordinator)
        defer { detach(map) }

        let far = CGPoint(x: map.bounds.maxX - 10, y: map.bounds.midY)
        #expect(coordinator.trailDraftLegIndex(at: far, in: map) == nil)
        #endif
    }

    // MARK: Pressing a pin

    @Test("a press on a pin finds the waypoint under it")
    func pressFindsAWaypoint() async {
        #if os(iOS)
        let coordinator = MapView.Coordinator()
        let map = await drawnLine(coordinator)
        defer { detach(map) }

        let onTheFirstPin = map.convert(
            Self.drawnCoordinate(Drawn.south),
            toPointTo: map
        )
        #expect(coordinator.trailDraftWaypointIndex(at: onTheFirstPin, in: map) == 0)

        let onTheSecond = map.convert(Self.drawnCoordinate(Drawn.north), toPointTo: map)
        #expect(coordinator.trailDraftWaypointIndex(at: onTheSecond, in: map) == 1)
        #endif
    }

    @Test("a press between the pins takes hold of neither")
    func pressBetweenPinsHoldsNothing() async {
        #if os(iOS)
        let coordinator = MapView.Coordinator()
        let map = await drawnLine(coordinator)
        defer { detach(map) }

        let halfway = CGPoint(x: map.bounds.midX, y: map.bounds.midY)
        #expect(coordinator.trailDraftWaypointIndex(at: halfway, in: map) == nil)
        #expect(!coordinator.beginTrailDraftDrag(at: halfway, in: map))
        #endif
    }

    /// The whole gesture, from the press to the drop, and the claim that makes
    /// it worth doing this way rather than with `MKAnnotationView.isDraggable`:
    /// the **line follows the finger**, not only the dot.
    @Test("dragging a pin moves it and bends the leg it is an end of")
    func draggingMovesThePinAndTheLine() async throws {
        #if os(iOS)
        let coordinator = MapView.Coordinator()
        let map = await drawnLine(coordinator)
        defer { detach(map) }

        let onTheSecondPin = map.convert(
            Self.drawnCoordinate(Drawn.north),
            toPointTo: map
        )
        #expect(coordinator.beginTrailDraftDrag(at: onTheSecondPin, in: map))
        // The map stops moving under a point that is moving over it.
        #expect(!map.isScrollEnabled)

        let moved = CGPoint(x: map.bounds.midX + 60, y: map.bounds.midY - 60)
        coordinator.moveTrailDraftDrag(to: moved, in: map)
        let held = try #require(trailMaker.draft.drag)
        #expect(held.index == 1)

        // The pin and the line both follow, and the list does not.
        await settle(until: "the held point to be drawn where it is held") {
            coordinator.trailDraftAnnotations.last?.coordinate.latitude == held.latitude
        }
        let bent = try #require(coordinator.trailDraftOverlays.first)
        #expect(bent.pointCount == 2, "a leg being dragged is a straight rubber band")
        #expect(
            trailMaker.draft.waypoints[1].latitude == Drawn.north,
            "the drawing itself does not change until the finger lifts"
        )

        coordinator.endTrailDraftDrag(on: map)

        #expect(map.isScrollEnabled, "the map gets its own gestures back")
        #expect(trailMaker.draft.drag == nil)
        #expect(trailMaker.draft.waypoints[1].latitude == held.latitude)
        #endif
    }

    @Test("a cancelled drag puts the pin back and hands the map its gestures")
    func cancellingADragPutsItBack() async {
        #if os(iOS)
        let coordinator = MapView.Coordinator()
        let map = await drawnLine(coordinator)
        defer { detach(map) }

        let onTheSecondPin = map.convert(
            Self.drawnCoordinate(Drawn.north),
            toPointTo: map
        )
        #expect(coordinator.beginTrailDraftDrag(at: onTheSecondPin, in: map))
        coordinator.moveTrailDraftDrag(
            to: CGPoint(x: map.bounds.midX + 60, y: map.bounds.midY),
            in: map
        )

        coordinator.cancelTrailDraftDrag(on: map)

        #expect(map.isScrollEnabled)
        #expect(trailMaker.draft.drag == nil)
        #expect(trailMaker.draft.waypoints[1].latitude == Drawn.north)
        await settle(until: "the pin to be drawn back where it was") {
            coordinator.trailDraftAnnotations.last?.coordinate.latitude == Drawn.north
        }
        #endif
    }

    /// Nothing about this gesture is felt unless a pin is under it: the press
    /// that would take hold of one is refused everywhere else, so panning,
    /// zooming and the tap that puts a point down are exactly what they were.
    @Test("the drag recognizer refuses to begin away from a pin")
    func theRecognizerRefusesAwayFromAPin() async throws {
        #if os(iOS)
        let coordinator = MapView.Coordinator()
        let map = await drawnLine(coordinator)
        defer { detach(map) }
        let recognizer = try #require(coordinator.trailDraftDragRecognizer)

        // Its own tap recognizer is never refused, whatever is underneath it.
        let tap = try #require(coordinator.routeTapRecognizer)
        #expect(coordinator.gestureRecognizerShouldBegin(tap))
        // And this one is refused, because a press is answered here only over
        // a pin. A recognizer that has seen no touch reports the origin, which
        // is the top corner of a map whose two pins are down its middle —
        // which is exactly the ordinary case this refuses.
        #expect(!coordinator.gestureRecognizerShouldBegin(recognizer))
        #endif
    }

    @Test("nothing is taken hold of while the maker is closed")
    func noDragWhileClosed() async {
        #if os(iOS)
        let coordinator = MapView.Coordinator()
        let map = await drawnLine(coordinator)
        defer { detach(map) }
        let onTheFirstPin = map.convert(
            Self.drawnCoordinate(Drawn.south),
            toPointTo: map
        )
        trailMaker.setEditing(false)
        await settle(until: "the line to be taken down") {
            coordinator.trailDraftCoordinates.isEmpty
        }

        #expect(coordinator.trailDraftWaypointIndex(at: onTheFirstPin, in: map) == nil)
        #expect(!coordinator.beginTrailDraftDrag(at: onTheFirstPin, in: map))
        #endif
    }
}
