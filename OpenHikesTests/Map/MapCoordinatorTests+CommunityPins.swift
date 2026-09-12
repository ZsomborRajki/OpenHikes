//
//  MapCoordinatorTests+CommunityPins.swift
//  OpenHikesTests
//
//  What the map does with the shared hikes in the list.
//
//  The feature's whole premise is that the map is the query — a region goes to
//  ``CommunityBrowser`` and a page of listings comes back — and for a while
//  the answer was drawn only as rows in a sheet over the map that asked. These
//  pin the other direction: that the results reach MapKit, that they reach it
//  without SwiftUI in between, and that a tap on one leads back to the same
//  preview the row opens.
//
//  As with the photo pins, the assertions name MapKit's own classes on
//  purpose. A custom annotation view here would look identical in a
//  screenshot and lose the drop, the selection growth and the decluttering.
//

import CoreLocation
import Foundation
import MapKit
@testable import OpenHikes
import SwiftUI
import Testing

extension MapCoordinatorTests {
    /// A region over the Thumsee, wide enough to be a real question and well
    /// inside the policy's zoom ceiling.
    private enum Area {
        static let latitude: Double = 47.63
        static let longitude: Double = 12.86
        static let spanMeters: Double = 20_000
        static let metersPerDegree: Double = 111_320
    }

    private static func region(latitude: Double = Area.latitude) -> MKCoordinateRegion {
        let degrees = Area.spanMeters / Area.metersPerDegree
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: latitude, longitude: Area.longitude),
            span: MKCoordinateSpan(latitudeDelta: degrees, longitudeDelta: degrees)
        )
    }

    /// A browser holding two published hikes, without anything having to
    /// happen on a network.
    private func loadedBrowser(
        _ listings: [CommunityListing]
    ) async -> (browser: CommunityBrowser, transport: StubCommunityTransport) {
        let transport = StubCommunityTransport()
        transport.listingsResult = .success(listings)
        let browser = CommunityBrowser(transport: transport, blockList: .scratch())
        browser.regionDidSettle(Self.region())
        browser.startBrowsing()
        while browser.requestsInFlight > 0 {
            await Task.yield()
        }
        return (browser, transport)
    }

    @Test("a walker who has not opted in gets no pins")
    func nothingIsDrawnBeforeOptingIn() {
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(), coordinator)
        defer { detach(map) }

        #expect(coordinator.communityAnnotations.isEmpty)
        #expect(!map.annotations.contains { $0 is CommunityMapAnnotation })
    }

    /// The loop this whole file is about: a region goes in, listings come
    /// back, and markers stand where they are — with no SwiftUI body between
    /// the answer and the map.
    @Test("published hikes become annotations on the map")
    func listingsBecomeAnnotations() async {
        let (browser, _) = await loadedBrowser([
            .stub(id: "ridge", latitude: 47.63, longitude: 12.86),
            .stub(id: "summit", latitude: 47.64, longitude: 12.89),
        ])
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(community: browser), coordinator)
        defer { detach(map) }

        await settle(until: "the shared hikes to reach the map") {
            coordinator.communityAnnotations.count == 2
        }
        #expect(coordinator.communityAnnotations.map(\.listing.id) == ["ridge", "summit"])
        #expect(map.annotations.compactMap { $0 as? CommunityMapAnnotation }.count == 2)
    }

    /// Hiding the section takes the pins with it. Rows the walker has put away
    /// must not be left standing on the map they were about.
    @Test("hiding the section takes the pins off the map")
    func hidingRemovesTheAnnotations() async {
        let (browser, _) = await loadedBrowser([.stub()])
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(community: browser), coordinator)
        defer { detach(map) }
        await settle(until: "the shared hike to reach the map") {
            !coordinator.communityAnnotations.isEmpty
        }

        browser.stopBrowsing()
        await settle(until: "the shared hike to leave the map") {
            coordinator.communityAnnotations.isEmpty
        }
        #expect(!map.annotations.contains { $0 is CommunityMapAnnotation })
    }

    /// Rebuilding drops and re-drops every marker, which is a visible
    /// animation on a map the walker is looking at — and closes a callout they
    /// had open. A republish of the same listings has to be free.
    @Test("republishing the same listings leaves the annotations alone")
    func anUnchangedCommunityRepublishKeepsTheAnnotations() async throws {
        let listing = CommunityListing.stub()
        let (browser, _) = await loadedBrowser([listing])
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(community: browser), coordinator)
        defer { detach(map) }
        await settle(until: "the shared hike to reach the map") {
            !coordinator.communityAnnotations.isEmpty
        }
        let original = try #require(coordinator.communityAnnotations.first)

        coordinator.applyCommunityPins([listing], on: map)

        #expect(coordinator.communityAnnotations.first === original)
    }

    /// Built out of MapKit's pieces on purpose — see the file header — and
    /// deliberately *not* in the route's tint, which belongs to the walker's
    /// own selected hike and may well be drawn on the same screen.
    @Test("a shared hike is a marker with a callout that opens it")
    func aCommunityPinUsesMapKitsMarkerAndCallout() async throws {
        #if os(iOS)
        let (browser, _) = await loadedBrowser([.stub()])
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(community: browser), coordinator)
        defer { detach(map) }
        await settle(until: "the shared hike to reach the map") {
            !coordinator.communityAnnotations.isEmpty
        }
        let annotation = try #require(coordinator.communityAnnotations.first)

        let view = try #require(
            coordinator.mapView(map, viewFor: annotation) as? MKMarkerAnnotationView
        )
        #expect(view.canShowCallout)
        #expect(view.glyphImage != nil)
        // One of a page of results rather than a place the walker asked to be
        // shown, so MapKit may hide it behind a neighbour.
        #expect(view.displayPriority == .defaultHigh)
        #expect(view.rightCalloutAccessoryView != nil)
        #expect(view.accessibilityIdentifier == "community-hike-pin")
        #expect(view.accessibilityLabel?.isEmpty == false)
        #expect(annotation.title == "Pilis Ridge")
        #expect(annotation.subtitle?.isEmpty == false)
        #endif
    }

    /// Three kinds of annotation share one delegate callback, and the branch
    /// between them is what is worth pinning: a shared hike drawn as an 18pt
    /// scrub dot is the failure this catches.
    @Test("the selection dot and a shared hike get different views")
    func theHighlightDotIsNotACommunityPin() async throws {
        let (browser, _) = await loadedBrowser([.stub()])
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(community: browser), coordinator)
        defer { detach(map) }
        await settle(until: "the shared hike to reach the map") {
            !coordinator.communityAnnotations.isEmpty
        }
        let pin = try #require(coordinator.communityAnnotations.first)

        let dot = MKPointAnnotation()
        dot.coordinate = CLLocationCoordinate2D(latitude: 47.64, longitude: 12.89)
        let dotView = try #require(coordinator.mapView(map, viewFor: dot))

        #expect(coordinator.mapView(map, viewFor: pin) is MKMarkerAnnotationView)
        #expect(!(dotView is MKMarkerAnnotationView))
        #expect(!dotView.canShowCallout)
    }

    /// The way back into the sheet. The map cannot see the navigation stack,
    /// so the destination is a closure the root view sets — and a pin whose
    /// tap reached nothing would be a marker that does nothing at all.
    @Test("tapping a pin's callout opens that hike")
    func tappingTheCalloutOpensTheListing() async throws {
        #if os(iOS)
        let (browser, _) = await loadedBrowser([.stub(id: "ridge")])
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(community: browser), coordinator)
        defer { detach(map) }
        await settle(until: "the shared hike to reach the map") {
            !coordinator.communityAnnotations.isEmpty
        }
        let annotation = try #require(coordinator.communityAnnotations.first)
        let view = try #require(
            coordinator.mapView(map, viewFor: annotation) as? MKMarkerAnnotationView
        )
        let accessory = try #require(view.rightCalloutAccessoryView as? UIControl)

        var opened: [String] = []
        browser.onOpenListing { opened.append($0.id) }
        coordinator.mapView(map, annotationView: view, calloutAccessoryControlTapped: accessory)

        #expect(opened == ["ridge"])
        #endif
    }

    /// `withObservationTracking` has no way to cancel a registration, so a
    /// second one is permanent: two observers rebuilding the same annotations
    /// for the life of the map.
    @Test("observing the pins twice registers nothing the second time")
    func communityPinObservationIsIdempotent() async {
        let (browser, _) = await loadedBrowser([.stub()])
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(community: browser), coordinator)
        defer { detach(map) }
        #expect(coordinator.isObservingCommunityPins)
        await settle(until: "the shared hike to reach the map") {
            !coordinator.communityAnnotations.isEmpty
        }

        let second = CommunityBrowser(transport: nil, blockList: .scratch())
        coordinator.observeCommunityPins(second, on: map)

        // The second browser holds nothing; had it registered, its empty list
        // would have taken the first one's pins off the map.
        await settle()
        #expect(coordinator.communityAnnotations.count == 1)
    }
}
