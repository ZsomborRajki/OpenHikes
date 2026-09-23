//
//  MapCoordinatorTests+TrailDraftDiffing.swift
//  OpenHikesTests
//
//  What a commit touches on the map, and what it leaves alone.
//
//  The draft's pins and lines used to be taken off the map and put back on
//  every commit — every leg that landed, every name that arrived — which closed
//  whatever callout was open and made every pin flicker once per answer. These
//  hold the diff that replaced it to *identity*: the same `MKPolyline` and the
//  same annotation object, not merely an equal one. And, beside them, the map's
//  own labels, which a tap may pick only while drawing on Apple's base map.
//

import CoreLocation
import Foundation
import MapKit
@testable import OpenHikes
import Testing

extension MapCoordinatorTests {
    private enum Line {
        static let longitude: Double = -122.0300
        static let first: Double = 37.3300
        static let second: Double = 37.3330
        static let third: Double = 37.3360
        static let fourth: Double = 37.3390

        static func at(_ latitude: Double) -> CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }
    }

    private static func routedMaker() -> TrailDraftController {
        let maker = TrailDraftController(router: StubTrailLegRouter(answering: .snapped))
        maker.setEditing(true)
        return maker
    }

    @Test("a new leg adds its own line and keeps every line and pin already drawn")
    func aNewLegTouchesOnlyItself() async {
        #if os(iOS)
        let maker = Self.routedMaker()
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(trailMaker: maker), coordinator)
        defer { detach(map) }

        for latitude in [Line.first, Line.second, Line.third] {
            maker.appendWaypoint(at: Line.at(latitude))
        }
        await settle(until: "both legs to land") {
            coordinator.trailDraftLegs.count == 2
                && coordinator.trailDraftLegs.allSatisfy { $0.snap == .snapped }
        }
        let pins = coordinator.trailDraftAnnotations
        let lines = coordinator.trailDraftOverlays

        maker.appendWaypoint(at: Line.at(Line.fourth))
        await settle(until: "the third leg to land") {
            coordinator.trailDraftLegs.count == 3
                && coordinator.trailDraftLegs.allSatisfy { $0.snap == .snapped }
        }

        let after = coordinator.trailDraftAnnotations
        #expect(after.count == 4)
        #expect(zip(pins, after.prefix(3)).allSatisfy { $0 === $1 }, "every pin already drawn is the same pin")
        #expect(
            zip(lines, coordinator.trailDraftOverlays.prefix(2)).allSatisfy { $0 === $1 },
            "every line already drawn is the same line"
        )
        #expect(map.overlays.count(where: { $0 is MKPolyline }) == 3, "and nothing is left behind")
        // The old destination is a stop now, in place.
        #expect(after[2].role == .stop(number: 2))
        #expect(after[3].role == .end)
        #endif
    }

    @Test("a stop being named retitles its pin without replacing it")
    func aNameRetitlesThePinInPlace() async throws {
        #if os(iOS)
        let maker = TrailDraftController()
        maker.setEditing(true)
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(trailMaker: maker), coordinator)
        defer { detach(map) }

        maker.appendWaypoint(at: Line.at(Line.first))
        maker.appendWaypoint(at: Line.at(Line.second))
        await settle(until: "both pins to be drawn") {
            coordinator.trailDraftAnnotations.count == 2
        }
        let pin = try #require(coordinator.trailDraftAnnotations.last)
        #expect(pin.title == TrailStopRole.end.title)

        maker.draft.describe(waypointWith: pin.waypointID, as: "Gellért-hegy")
        await settle(until: "the pin to take the name") { pin.title == "Gellért-hegy" }

        #expect(coordinator.trailDraftAnnotations.last === pin)
        #expect(map.annotations.contains { $0 === pin })
        #endif
    }

    // MARK: The map's own labels

    @Test("the map's labels are selectable only while drawing on Apple's own map")
    func labelsAreSelectableOnlyWhileDrawingOnAppleMaps() async {
        #if os(iOS)
        let maker = TrailDraftController()
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(tileSource: nil, trailMaker: maker), coordinator)
        defer { detach(map) }
        #expect(map.selectableMapFeatures.isEmpty, "a label means nothing to the app outside the maker")

        maker.setEditing(true)
        await settle(until: "the labels to become selectable") {
            map.selectableMapFeatures == [.pointsOfInterest, .physicalFeatures]
        }
        #expect(map.selectableMapFeatures == [.pointsOfInterest, .physicalFeatures])

        maker.setEditing(false)
        await settle(until: "the labels to stop being selectable") {
            map.selectableMapFeatures.isEmpty
        }
        #expect(map.selectableMapFeatures.isEmpty)

        // Over OpenStreetMap tiles Apple's labels are not drawn, so none is
        // selectable even while drawing.
        let osmCoordinator = MapView.Coordinator()
        let osmMap = makeMap(mapView(trailMaker: maker), osmCoordinator)
        defer { detach(osmMap) }
        maker.setEditing(true)
        maker.appendWaypoint(at: Line.at(Line.first))
        await settle(until: "the maker's pass to draw on the OpenStreetMap map") {
            osmCoordinator.trailDraftAnnotations.count == 1
        }
        #expect(osmMap.selectableMapFeatures.isEmpty)
        #endif
    }

    /// What a label tap becomes once MapKit has handed it over: the maker's own
    /// dropped pin, headed with the label's name, a place sheet that says it,
    /// and a stop that arrives named.
    @Test("a pin dropped on a named place carries the name to the stop it becomes")
    func aNamedPinNamesItsStop() async throws {
        #if os(iOS)
        let maker = TrailDraftController()
        maker.setEditing(true)
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(tileSource: nil, trailMaker: maker), coordinator)
        defer { detach(map) }

        let spot = TrailDraftDroppedPinSpot(coordinate: Line.at(Line.first), leg: nil, name: "Watzmann")
        maker.dropPin(spot)
        #expect(maker.selection == .droppedPin)
        await settle(until: "the named pin to be drawn") { coordinator.trailDraftDroppedPin != nil }
        let pin = try #require(coordinator.trailDraftDroppedPin)
        #expect(pin.title == "Watzmann")

        let card = try #require(TrailPlaceCard(.droppedPin, in: maker.draft, droppedPin: maker.droppedPin))
        #expect(card.title == "Watzmann")
        #expect(card.isDroppedPin)
        guard case let .addStop(name, leg) = card.primary else {
            Issue.record("a dropped pin's card offers Add Stop")
            return
        }
        maker.addStop(at: card.coordinate, named: name, preferringLeg: leg)
        #expect(maker.draft.waypoints.map(\.name) == ["Watzmann"])
        #endif
    }

    /// The map's own tap sees the touch that selected a label, in either order
    /// against MapKit's selection, and on open ground a tap closes the card.
    /// When the label got there first, the tap must not close the card it
    /// has just opened — see `MapTrailDraftFeatures.swift`.
    @Test("a tap beside a named pin just dropped leaves its card open, and one elsewhere closes it")
    func aTapBesideANamedPinKeepsIt() {
        #if os(iOS)
        let maker = TrailDraftController()
        maker.setEditing(true)
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(tileSource: nil, trailMaker: maker), coordinator)
        defer { detach(map) }
        map.setRegion(
            MKCoordinateRegion(center: Line.at(Line.second), latitudinalMeters: 2000, longitudinalMeters: 2000),
            animated: false
        )

        let centre = CGPoint(x: map.bounds.midX, y: map.bounds.midY)
        let named = TrailDraftDroppedPinSpot(
            coordinate: map.convert(centre, toCoordinateFrom: map),
            leg: nil,
            name: "Watzmann"
        )
        maker.dropPin(named)

        // Whether the tap is answered here or claimed by the pin's own view is
        // a matter of whether MapKit has drawn it yet; either way the card
        // stays open.
        coordinator.handleTrailDraftTap(at: centre, in: map)
        #expect(maker.selection == .droppedPin, "the label's card stays open")
        #expect(maker.droppedPin == named)

        let elsewhere = CGPoint(x: map.bounds.midX, y: map.bounds.midY + 120)
        #expect(coordinator.handleTrailDraftTap(at: elsewhere, in: map))
        #expect(maker.selection == nil, "a tap away from the label is a tap on open map")
        #expect(maker.droppedPin == named, "and it leaves the pin where it was")
        #endif
    }
}
