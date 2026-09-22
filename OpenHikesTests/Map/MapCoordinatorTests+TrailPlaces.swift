//
//  MapCoordinatorTests+TrailPlaces.swift
//  OpenHikesTests
//
//  The callout's buttons and the place pins, against a real `MKMapView`.
//
//  Two halves that cannot be reached anywhere else. What a callout button
//  *does* is ``MapView/Coordinator/applyTrailDraftPin(_:at:legIndex:named:in:)``,
//  and restating its decision in a suite of its own would be a mirror with no
//  compiler behind it — so it is driven here, where the coordinator is real.
//  And a place pin's marker, glyph, callout and the tap rules around it are
//  MapKit's own views, which only a real map has.
//
//  What is asserted next door instead: ``TrailDraftPinActionTests`` for which
//  verbs a callout offers, ``TrailDraftPlaceTests`` for what marking one does
//  to the draft, and ``TrailPlaceTests`` for where along a line it sits.
//

import CoreLocation
import MapKit
@testable import OpenHikes
import Testing
#if canImport(UIKit)
import UIKit
#endif

extension MapCoordinatorTests {
    /// A north-running line inside the region ``makeMap`` frames.
    ///
    /// Its own copy rather than `MapCoordinatorTests+TrailDraft`'s `Ridge`,
    /// which is `private` and so file-scoped. Three latitudes here where that
    /// one has two, because the verb this file is about — *Add Stop* — needs a
    /// middle to be inserted beside.
    private enum Place {
        static let longitude: Double = -122.0300
        static let south: Double = 37.3300
        static let middle: Double = 37.3350
        static let north: Double = 37.3400
    }

    private static func placeCoordinate(_ latitude: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: Place.longitude)
    }

    // MARK: What a callout button does

    /// *Start Here*, *Set as Destination* and *Make Destination* are the same
    /// edit at three lengths of line — a point on the end — and the words
    /// differ because what they mean to a hiker does.
    @Test("the three route verbs all put a point on the end")
    func routeVerbsAppend() {
        #if os(iOS)
        for verb in [TrailDraftPinAction.startHere, .setAsDestination, .makeDestination] {
            let coordinator = MapView.Coordinator()
            let map = makeMap(mapView(), coordinator)
            defer { detach(map) }
            trailMaker.setEditing(true)
            trailMaker.appendWaypoint(at: Self.placeCoordinate(Place.south))

            coordinator.applyTrailDraftPin(
                verb,
                at: Self.placeCoordinate(Place.north),
                legIndex: nil,
                named: "",
                in: map
            )

            #expect(trailMaker.draft.waypoints.count == 2, "\(verb)")
            #expect(trailMaker.draft.waypoints.last?.latitude == Place.north, "\(verb)")
            trailMaker.discard()
            trailMaker.setEditing(false)
        }
        #endif
    }

    /// The leg the thumb was on, rather than the one that is nearest by the
    /// time the button is pressed: the two differ where a trail doubles back,
    /// and the hiker aimed at pixels.
    @Test("a stop goes into the leg the tap remembered")
    func aStopUsesTheRememberedLeg() throws {
        #if os(iOS)
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(), coordinator)
        defer { detach(map) }
        trailMaker.setEditing(true)
        trailMaker.appendWaypoint(at: Self.placeCoordinate(Place.south))
        trailMaker.appendWaypoint(at: Self.placeCoordinate(Place.middle))
        trailMaker.appendWaypoint(at: Self.placeCoordinate(Place.north))

        // Geometrically nearest the *first* leg, but the tap says the second.
        coordinator.applyTrailDraftPin(
            .addStop,
            at: Self.placeCoordinate(Place.south + 0.0005),
            legIndex: 1,
            named: "",
            in: map
        )

        #expect(trailMaker.draft.waypoints.count == 4)
        let inserted = try #require(trailMaker.draft.waypoints.dropFirst(2).first)
        #expect(inserted.latitude == Place.south + 0.0005)
        #endif
    }

    /// A tap on open map remembers no leg, so the ground decides — see
    /// ``TrailDraft/nearestLegIndex(to:)``.
    @Test("a stop with no remembered leg falls into the nearest one")
    func aStopWithoutALegUsesTheNearest() throws {
        #if os(iOS)
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(), coordinator)
        defer { detach(map) }
        trailMaker.setEditing(true)
        trailMaker.appendWaypoint(at: Self.placeCoordinate(Place.south))
        trailMaker.appendWaypoint(at: Self.placeCoordinate(Place.middle))
        trailMaker.appendWaypoint(at: Self.placeCoordinate(Place.north))

        coordinator.applyTrailDraftPin(
            .addStop,
            at: Self.placeCoordinate(Place.middle + 0.0005),
            legIndex: nil,
            named: "",
            in: map
        )

        let inserted = try #require(trailMaker.draft.waypoints.dropFirst(2).first)
        #expect(inserted.latitude == Place.middle + 0.0005, "it belongs in the second leg")
        #endif
    }

    /// Marking and naming are one gesture from the hiker's side, so the button
    /// that marks is also what asks the screen to open the editor.
    @Test("marking a place from the callout opens the editor on it")
    func markingOpensTheEditor() throws {
        #if os(iOS)
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(), coordinator)
        defer { detach(map) }
        trailMaker.setEditing(true)

        coordinator.applyTrailDraftPin(
            .markAPlace,
            at: Self.placeCoordinate(Place.middle),
            legIndex: nil,
            named: "",
            in: map
        )

        let place = try #require(trailMaker.draft.places.first)
        #expect(trailMaker.placeEditorRequest?.placeID == place.id)
        #expect(trailMaker.draft.waypoints.isEmpty, "marking a place is not drawing")
        #endif
    }

    /// **The first close of a dropped pin's callout is the map's, not the
    /// hiker's** — see ``TrailDraftDroppedPin/mayReopen``. Without this the
    /// callout went up and came down a moment later, every time, and ten of
    /// `TrailMakerUITests` failed saying the buttons were never there. It was
    /// measured again after the route tap started requiring MapKit's own double
    /// tap to fail: the close moved from +500 ms to +150 ms and did not go
    /// away, because the recognizer that does it is not on the map view.
    ///
    /// **The reopen is synchronous, and that is the half a hiker can see.** It
    /// used to hop a runloop turn and animate, which drew the callout closing
    /// and opening again; reopening inside this callback means no frame is
    /// drawn without it. Asserting it here is asserting that there is no hop:
    /// the pin is selected again by the time this call returns, with nothing
    /// awaited in between.
    @Test("the map closing a dropped pin's callout opens it again at once, once")
    func theFirstDismissalReopensTheCallout() async throws {
        #if os(iOS)
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(), coordinator)
        defer { detach(map) }
        map.setRegion(
            MKCoordinateRegion(
                center: Self.placeCoordinate(Place.middle),
                latitudinalMeters: 4000,
                longitudinalMeters: 4000
            ),
            animated: false
        )
        trailMaker.setEditing(true)
        #expect(
            coordinator.dropTrailDraftPin(
                at: CGPoint(x: map.bounds.midX, y: map.bounds.midY),
                in: map
            )
        )
        let pin = try #require(coordinator.trailDraftDroppedPin)
        let view = try #require(coordinator.mapView(map, viewFor: pin))

        coordinator.mapView(map, didDeselect: view)

        // Before any `await`, which is what says the reopen was synchronous.
        #expect(coordinator.trailDraftDroppedPin === pin, "the map's own dismissal is not the hiker's")
        #expect(!pin.mayReopen, "and the budget for it is spent")

        coordinator.mapView(map, didDeselect: view)
        await settleMainActor()

        #expect(coordinator.trailDraftDroppedPin == nil, "the second is, and takes the pin")
        #expect(!map.annotations.contains { $0 is TrailDraftDroppedPin })
        #endif
    }

    // MARK: The place pins

    @Test("the draft's places are drawn while the maker is up and taken down when it goes")
    func placesAreDrawnWhileEditing() async {
        #if os(iOS)
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(), coordinator)
        defer { detach(map) }
        trailMaker.setEditing(true)

        trailMaker.markPlace(at: Self.placeCoordinate(Place.middle), named: "Spring", symbol: .water)
        await settle(until: "the place to be pinned") {
            !coordinator.trailDraftPlaceAnnotations.isEmpty
        }
        #expect(map.annotations.contains { $0 is TrailPlaceAnnotation })
        #expect(coordinator.trailDraftPlaceAnnotations.first?.place.name == "Spring")
        #expect(coordinator.trailDraftPlaceAnnotations.first?.isEditable == true)

        trailMaker.setEditing(false)
        await settle(until: "the place to be taken down") {
            coordinator.trailDraftPlaceAnnotations.isEmpty
        }
        #expect(!map.annotations.contains { $0 is TrailPlaceAnnotation })
        #endif
    }

    /// A place is renamed and re-symboled without moving, and the pin has to
    /// follow: the guard in front of the rebuild compares the whole row rather
    /// than the coordinate.
    @Test("renaming a place redraws its pin")
    func renamingAPlaceRedrawsIt() async throws {
        #if os(iOS)
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(), coordinator)
        defer { detach(map) }
        trailMaker.setEditing(true)
        let place = try #require(trailMaker.markPlace(at: Self.placeCoordinate(Place.middle)))
        await settle(until: "the place to be pinned") {
            !coordinator.trailDraftPlaceAnnotations.isEmpty
        }

        var renamed = place
        renamed.name = "Kühroint"
        renamed.symbol = .shelter
        trailMaker.updatePlace(renamed)

        await settle(until: "the pin to follow the name") {
            coordinator.trailDraftPlaceAnnotations.first?.place.name == "Kühroint"
        }
        #expect(coordinator.trailDraftPlaceAnnotations.first?.place.symbol == .shelter)
        #endif
    }

    /// The other source, and the one a saved hike uses. A read-only pin offers
    /// no verbs — editing an existing hike is out of scope for this phase, and
    /// the flag is the whole of what says so.
    @Test("a saved hike's places are drawn read-only")
    func savedPlacesAreReadOnly() async throws {
        #if os(iOS)
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(), coordinator)
        defer { detach(map) }
        let row = TrailPlaceRow(
            place: TrailPlace(coordinate: Self.placeCoordinate(Place.middle), name: "Saddle"),
            anchor: TrailPlaceAnchor(distanceAlongRouteMeters: 1200, offRouteMeters: 4)
        )

        placePins.attach([row])

        await settle(until: "the hike's place to be pinned") {
            !coordinator.hikePlaceAnnotations.isEmpty
        }
        let annotation = try #require(coordinator.hikePlaceAnnotations.first)
        #expect(!annotation.isEditable)
        #expect(annotation.title == "Saddle")
        #expect(annotation.subtitle?.isEmpty == false, "a saved place says how far along it sits")
        // The verbs are what *this* phase decides, and their absence is the
        // whole of "read-only": a saved place with no note has nothing to put
        // in its callout at all, so the accessory is cleared rather than left
        // as an empty band of card.
        //
        // Deliberately not asserted here: `canShowCallout`. It is set on every
        // one of these views, but it is a property of a view MapKit recycles
        // and a full run reads it back `false` off a view a previous test
        // returned to the pool — which says something about MapKit's reuse
        // rather than about this code.
        let view = try #require(coordinator.mapView(map, viewFor: annotation))
        #expect(view.detailCalloutAccessoryView == nil, "a read-only place offers no verbs")
        #endif
    }

    /// And the editable half of that pair: the maker's own pins carry *Edit*
    /// and *Remove*, which is the one difference between the two sources.
    @Test("the maker's own places offer the two verbs")
    func editablePlacesOfferTheVerbs() async throws {
        #if os(iOS)
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(), coordinator)
        defer { detach(map) }
        trailMaker.setEditing(true)
        trailMaker.markPlace(at: Self.placeCoordinate(Place.middle), named: "Spring", symbol: .water)
        await settle(until: "the place to be pinned") {
            !coordinator.trailDraftPlaceAnnotations.isEmpty
        }
        let annotation = try #require(coordinator.trailDraftPlaceAnnotations.first)

        let view = try #require(coordinator.mapView(map, viewFor: annotation))

        let callout = try #require(view.detailCalloutAccessoryView as? TrailPlaceCalloutView)
        let identifiers = callout.descendantIdentifiers()
        #expect(identifiers.contains(TrailPlaceCalloutView.editIdentifier))
        #expect(identifiers.contains(TrailPlaceCalloutView.removeIdentifier))
        #endif
    }

    /// The claim is handed back when the screen goes, which is what stops a
    /// hike's pins outliving the screen they belong to.
    @Test("a saved hike's places come off the map when its screen goes")
    func savedPlacesAreWithdrawn() async {
        #if os(iOS)
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(), coordinator)
        defer { detach(map) }
        let token = placePins.attach([
            TrailPlaceRow(
                place: TrailPlace(coordinate: Self.placeCoordinate(Place.middle)),
                anchor: nil
            ),
        ])
        await settle(until: "the hike's place to be pinned") {
            !coordinator.hikePlaceAnnotations.isEmpty
        }

        placePins.detach(token: token)

        await settle(until: "the hike's place to be taken down") {
            coordinator.hikePlaceAnnotations.isEmpty
        }
        #expect(!map.annotations.contains { $0 is TrailPlaceAnnotation })
        #endif
    }

    /// A pop's animation runs before the leaving screen's `onDisappear`, so
    /// the pins are withdrawn on the sheet's own signal rather than waiting to
    /// be detached — the reason ``PhotoMapPinController`` has the same pair.
    @Test("a saved hike's places come off while no screen is pushed")
    func savedPlacesFollowTheHostScreen() async {
        #if os(iOS)
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(), coordinator)
        defer { detach(map) }
        placePins.attach([
            TrailPlaceRow(
                place: TrailPlace(coordinate: Self.placeCoordinate(Place.middle)),
                anchor: nil
            ),
        ])
        await settle(until: "the hike's place to be pinned") {
            !coordinator.hikePlaceAnnotations.isEmpty
        }

        placePins.setHostScreenPresent(false)

        await settle(until: "the hike's place to be taken down") {
            coordinator.hikePlaceAnnotations.isEmpty
        }
        placePins.setHostScreenPresent(true)
        await settle(until: "the hike's place to come back") {
            !coordinator.hikePlaceAnnotations.isEmpty
        }
        #endif
    }
}

#if os(iOS)
private extension UIView {
    /// Every accessibility identifier in this view's tree.
    ///
    /// The callout's buttons are what `TrailMakerUITests` reaches by name, and
    /// a suite that cannot see a name here is one that would find out on a
    /// simulator thirteen minutes later.
    func descendantIdentifiers() -> Set<String> {
        var found: Set<String> = []
        if let identifier = accessibilityIdentifier { found.insert(identifier) }
        for subview in subviews { found.formUnion(subview.descendantIdentifiers()) }
        return found
    }
}
#endif

#if os(iOS)
extension MapCoordinatorTests {
    /// Lets the main queue run the hop `dismissTrailDraftPin(for:on:)` takes.
    ///
    /// A hop rather than a wait: the work is already queued when this is
    /// called, so one turn of the queue is the effect rather than a duration
    /// to sleep for.
    func settleMainActor() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}
#endif
