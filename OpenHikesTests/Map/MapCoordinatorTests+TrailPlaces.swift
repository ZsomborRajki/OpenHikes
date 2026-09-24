//
//  MapCoordinatorTests+TrailPlaces.swift
//  OpenHikesTests
//
//  The place pins, against a real `MKMapView`.
//
//  A place pin's marker, glyph and the tap rules around it are MapKit's own
//  views, which only a real map has. What is asserted next door instead:
//  ``TrailDraftPlaceTests`` for what adding one does to the draft, and
//  ``TrailPlaceTests`` for where along a line it sits.
//

import CoreLocation
import MapKit
@testable import OpenHikes
import SwiftUI
import Testing
#if canImport(UIKit)
import UIKit
#endif

extension MapCoordinatorTests {
    /// A north-running line inside the region ``makeMap`` frames.
    ///
    /// Its own copy rather than `MapCoordinatorTests+TrailDraft`'s `Ridge`,
    /// which is `private` and so file-scoped.
    private enum Place {
        static let longitude: Double = -122.0300
        static let middle: Double = 37.3350
    }

    private static func placeCoordinate(_ latitude: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: Place.longitude)
    }

    private static let spring = TrailPlace(
        coordinate: placeCoordinate(Place.middle),
        name: "Spring",
        symbol: .water
    )

    // MARK: The place pins

    @Test("the draft's places are drawn while the maker is up and taken down when it goes")
    func placesAreDrawnWhileEditing() async {
        #if os(iOS)
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(), coordinator)
        defer { detach(map) }
        trailMaker.setEditing(true)

        trailMaker.draft.addPlaces([Self.spring])
        await settle(until: "the place to be pinned") {
            !coordinator.trailDraftPlaceAnnotations.isEmpty
        }
        #expect(map.annotations.contains { $0 is TrailPlaceAnnotation })
        #expect(coordinator.trailDraftPlaceAnnotations.first?.place.name == "Spring")
        #expect(coordinator.trailDraftPlaceAnnotations.first?.belongsToDraft == true)

        trailMaker.setEditing(false)
        await settle(until: "the place to be taken down") {
            coordinator.trailDraftPlaceAnnotations.isEmpty
        }
        #expect(!map.annotations.contains { $0 is TrailPlaceAnnotation })
        #endif
    }

    /// The place sheet's *Remove* takes the pin with it.
    @Test("removing a place takes its pin off the map")
    func removingAPlaceTakesItsPin() async {
        #if os(iOS)
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(), coordinator)
        defer { detach(map) }
        trailMaker.setEditing(true)
        trailMaker.draft.addPlaces([Self.spring])
        await settle(until: "the place to be pinned") {
            !coordinator.trailDraftPlaceAnnotations.isEmpty
        }

        trailMaker.removePlace(id: Self.spring.id)

        await settle(until: "the pin to go") { coordinator.trailDraftPlaceAnnotations.isEmpty }
        #expect(!map.annotations.contains { $0 is TrailPlaceAnnotation })
        #endif
    }

    /// The other source, and the one a saved hike uses. A tap opens the
    /// place's own screen, through whichever screen drew the pin — there is
    /// no callout, whose MapKit-driven close is the race the maker's pins were
    /// taken off callouts for.
    @Test("a saved hike's place pin opens the place, with no callout")
    func savedPlacesOpenTheirScreen() async throws {
        #if os(iOS)
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(), coordinator)
        defer { detach(map) }
        let row = TrailPlaceRow(
            place: TrailPlace(coordinate: Self.placeCoordinate(Place.middle), name: "Saddle"),
            anchor: TrailPlaceAnchor(distanceAlongRouteMeters: 1200, offRouteMeters: 4)
        )
        var opened: [UUID] = []

        placePins.attach([row]) { opened.append($0) }

        await settle(until: "the hike's place to be pinned") {
            !coordinator.hikePlaceAnnotations.isEmpty
        }
        let annotation = try #require(coordinator.hikePlaceAnnotations.first)
        #expect(!annotation.belongsToDraft)
        #expect(annotation.title == "Saddle")
        #expect(annotation.subtitle?.isEmpty == false, "a saved place says how far along it sits")
        let view = try #require(coordinator.mapView(map, viewFor: annotation))
        #expect(view.detailCalloutAccessoryView == nil)

        #expect(coordinator.selectHikePlaceAnnotation(view, on: map))
        #expect(opened == [row.id])
        #endif
    }

    @Test("a pin whose screen has gone opens nothing")
    func detachedPinOpensNothing() {
        let row = TrailPlaceRow(place: Self.spring, anchor: nil)
        var opened = 0
        let token = placePins.attach([row]) { _ in opened += 1 }

        placePins.detach(token: token)

        #expect(placePins.open(row.id) == false)
        #expect(opened == 0)
    }

    /// And the maker's half of that pair: no callout, a colour for its kind,
    /// and a tap that opens the place sheet on it.
    @Test("the maker's own places open the place sheet")
    func draftPlacesOpenTheSheet() async throws {
        #if os(iOS)
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(), coordinator)
        defer { detach(map) }
        trailMaker.setEditing(true)
        trailMaker.draft.addPlaces([Self.spring])
        await settle(until: "the place to be pinned") {
            !coordinator.trailDraftPlaceAnnotations.isEmpty
        }
        let annotation = try #require(coordinator.trailDraftPlaceAnnotations.first)

        let view = try #require(coordinator.mapView(map, viewFor: annotation) as? MKMarkerAnnotationView)

        #expect(view.detailCalloutAccessoryView == nil)
        #expect(view.markerTintColor == UIColor(TrailPlaceSymbol.water.tint))
        #expect(coordinator.selectTrailDraftAnnotation(view, on: map))
        #expect(trailMaker.selection == .place(Self.spring.id))
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
