//
//  MapCoordinatorTests+PhotoPins.swift
//  OpenHikesTests
//
//  What the map does with a hike's photographs.
//
//  The interesting half is not that a marker appears — it is that the markers
//  are MapKit's own and are wired to MapKit's own callout, because that is the
//  part a rewrite would quietly replace with a custom annotation view and lose
//  the drop animation, the selection growth and the decluttering with. So the
//  assertions name the classes: an `MKMarkerAnnotationView`, a callout it is
//  allowed to show, and a ``PhotoCalloutPreview`` in the accessory slot Apple
//  provides for exactly this.
//
//  The other half is the render isolation the whole coordinator exists for. A
//  photo taken while a hike is open must redraw MapKit's annotations and
//  nothing else, and a republish that changes nothing must not even do that.
//

import CoreLocation
import Foundation
import MapKit
@testable import OpenHikes
import SwiftUI
import Testing

extension MapCoordinatorTests {
    /// Two points on the Thumsee ridge, far enough apart to be separate pins.
    private enum PhotoAnchor {
        static let bendLatitude: Double = 47.6301
        static let bendLongitude: Double = 12.8802
        static let summitLatitude: Double = 47.6412
        static let summitLongitude: Double = 12.8955
        static let startTimestamp: TimeInterval = 1_700_000_000
    }

    private static let bend = CLLocationCoordinate2D(
        latitude: PhotoAnchor.bendLatitude,
        longitude: PhotoAnchor.bendLongitude
    )
    private static let summit = CLLocationCoordinate2D(
        latitude: PhotoAnchor.summitLatitude,
        longitude: PhotoAnchor.summitLongitude
    )

    @Test("a hike with no photos puts nothing on the map")
    func noPhotosDrawNoPins() {
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(), coordinator)
        defer { detach(map) }

        #expect(coordinator.photoAnnotations.isEmpty)
        #expect(!map.annotations.contains { $0 is PhotoMapAnnotation })
    }

    @Test("pins published by a screen become annotations on the map")
    func publishedPinsBecomeAnnotations() async {
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(), coordinator)
        defer { detach(map) }

        let first = Self.photo(at: Self.bend, offset: 0)
        let second = Self.photo(at: Self.summit, offset: 60)
        photoPins.attach([first, second]) { _ in /* unused */ }
        await settle(until: "the photo pins to reach the map") {
            coordinator.photoAnnotations.count == 2
        }

        #expect(coordinator.photoAnnotations.map(\.pin.id) == [first.id, second.id])
        let placed = map.annotations.compactMap { $0 as? PhotoMapAnnotation }
        #expect(placed.count == 2)
    }

    @Test("a screen that goes away takes its pins off the map")
    func detachingRemovesTheAnnotations() async {
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(), coordinator)
        defer { detach(map) }

        let token = photoPins.attach([Self.photo(at: Self.bend, offset: 0)]) { _ in /* unused */ }
        await settle(until: "the photo pin to reach the map") {
            !coordinator.photoAnnotations.isEmpty
        }

        photoPins.detach(token: token)
        await settle(until: "the photo pin to leave the map") {
            coordinator.photoAnnotations.isEmpty
        }
        #expect(!map.annotations.contains { $0 is PhotoMapAnnotation })
    }

    /// Rebuilding drops and re-drops every marker, which is a visible animation
    /// on a map the user is looking at — and would close a callout they had
    /// open. A republish of the same list has to be free.
    @Test("republishing the same pins leaves the annotations alone")
    func anUnchangedRepublishKeepsTheAnnotations() async throws {
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(), coordinator)
        defer { detach(map) }

        let photo = Self.photo(at: Self.bend, offset: 0)
        photoPins.attach([photo]) { _ in /* unused */ }
        await settle(until: "the photo pin to reach the map") {
            !coordinator.photoAnnotations.isEmpty
        }
        let original = try #require(coordinator.photoAnnotations.first)

        coordinator.applyPhotoPins(PhotoMapPin.pins(for: [photo]), on: map)

        #expect(coordinator.photoAnnotations.first === original)
    }

    /// The pin is built out of MapKit's pieces on purpose — see the file
    /// header. A custom `MKAnnotationView` here would look the same in a
    /// screenshot and behave differently in every other respect.
    @Test("a photo pin is a marker with the photo in its callout")
    func aPhotoPinUsesMapKitsMarkerAndCallout() async throws {
        #if os(iOS)
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(), coordinator)
        defer { detach(map) }

        photoPins.attach([Self.photo(at: Self.bend, offset: 0)]) { _ in /* unused */ }
        await settle(until: "the photo pin to reach the map") {
            !coordinator.photoAnnotations.isEmpty
        }
        let annotation = try #require(coordinator.photoAnnotations.first)

        let view = try #require(
            coordinator.mapView(map, viewFor: annotation) as? MKMarkerAnnotationView
        )
        #expect(view.canShowCallout)
        #expect(view.glyphImage != nil)
        // A photo is a place the user asked to be shown; MapKit must not hide
        // it to declutter.
        #expect(view.displayPriority == .required)
        #expect(view.detailCalloutAccessoryView is PhotoCalloutPreview)
        #expect(view.accessibilityIdentifier == "photo-pin")
        #expect(view.accessibilityLabel?.isEmpty == false)
        #endif
    }

    /// The selection dot and the photo markers share one delegate callback, so
    /// the branch between them is the thing worth pinning: getting it wrong
    /// draws a photo pin as an 18pt dot, or the scrub position as a marker.
    @Test("the selection dot and a photo pin get different views")
    func theHighlightDotIsNotAPhotoPin() async throws {
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(), coordinator)
        defer { detach(map) }

        photoPins.attach([Self.photo(at: Self.bend, offset: 0)]) { _ in /* unused */ }
        await settle(until: "the photo pin to reach the map") {
            !coordinator.photoAnnotations.isEmpty
        }
        let pinAnnotation = try #require(coordinator.photoAnnotations.first)

        let dot = MKPointAnnotation()
        dot.coordinate = Self.summit
        let dotView = try #require(coordinator.mapView(map, viewFor: dot))

        #expect(coordinator.mapView(map, viewFor: pinAnnotation) is MKMarkerAnnotationView)
        #expect(!(dotView is MKMarkerAnnotationView))
        #expect(!dotView.canShowCallout)
    }

    /// A colour drag reaches the line through `observeRouteStyle`; the markers
    /// have to come with it, or a re-tinted route is left with pins in the
    /// previous hue until something else rebuilds them.
    @Test("the markers follow the route's tint")
    func markersAreRecolouredWithTheRoute() async throws {
        #if os(iOS)
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(), coordinator)
        defer { detach(map) }

        photoPins.attach([Self.photo(at: Self.bend, offset: 0)]) { _ in /* unused */ }
        await settle(until: "the photo pin to reach the map") {
            !coordinator.photoAnnotations.isEmpty
        }
        let annotation = try #require(coordinator.photoAnnotations.first)
        let view = try #require(
            coordinator.mapView(map, viewFor: annotation) as? MKMarkerAnnotationView
        )

        coordinator.routeTint = .purple
        coordinator.refreshPhotoPinColor(on: map)

        // `refreshPhotoPinColor` reaches the views MapKit is holding, which in
        // a test that never puts the map in a window is not the one built
        // above — so the assertion is on what a fresh view is given.
        let rebuilt = try #require(
            coordinator.mapView(map, viewFor: annotation) as? MKMarkerAnnotationView
        )
        #expect(rebuilt.markerTintColor == UIColor(.purple))
        #expect(view.markerTintColor != nil)
        #endif
    }

    /// `withObservationTracking` has no way to cancel a registration, so a
    /// second one is permanent: two observers rebuilding the same annotations
    /// for the life of the map.
    @Test("observing the pins twice registers nothing the second time")
    func pinObservationIsIdempotent() {
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(), coordinator)
        defer { detach(map) }
        #expect(coordinator.isObservingPhotoPins)

        let second = PhotoMapPinController()
        coordinator.observePhotoPins(second, on: map)

        #expect(coordinator.photoPinController === photoPins)
        #expect(coordinator.photoPinController !== second)
    }

    /// The callout keeps what a decode found out about the photo, because
    /// MapKit re-enters `show(_:store:onTap:)` for a pin that is reselected
    /// and that path deliberately does not decode again. The glyph survives it
    /// — the image view is untouched — so the sentence describing the glyph
    /// has to survive it too, or VoiceOver is told a photo is there while
    /// everyone else is being shown that it is not.
    @Test("reselecting a pin keeps what the callout found out about the photo")
    func aReselectedPinKeepsItsUnavailableLabel() async throws {
        #if os(iOS)
        // Its own directory, never `HikePhotoStore.shared`: the host app
        // writes into that one while this suite runs.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("photo-callout-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = HikePhotoStore(storageRoot: root)
        // A row with nothing behind it: the ordinary state of a photo added on
        // another device.
        let pin = try #require(
            PhotoMapPin.pins(for: [Self.photo(at: Self.bend, offset: 0)]).first
        )
        let preview = PhotoCalloutPreview(frame: .zero)
        preview.show(pin, store: store) { _ in /* unused */ }
        await settle(until: "the callout to find the photo is not on this device") {
            preview.accessibilityLabel?.hasSuffix("not on this device") == true
        }

        // The reselect.
        preview.show(pin, store: store) { _ in /* unused */ }

        #expect(preview.accessibilityLabel?.hasSuffix("not on this device") == true)
        #endif
    }

    private static func photo(
        at coordinate: CLLocationCoordinate2D,
        offset: TimeInterval
    ) -> HikePhoto {
        HikePhoto(
            capturedAt: Date(timeIntervalSince1970: PhotoAnchor.startTimestamp).addingTimeInterval(offset),
            coordinate: coordinate
        )
    }
}
