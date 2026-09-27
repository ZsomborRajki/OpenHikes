//
//  PhotoCaptureControllerPlaceTests.swift
//  OpenHikesTests
//
//  The pill's *Add Place*: offered only where the pill is, only for a screen
//  that says where a place would go, and resolved at the tap.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import Testing

/// A coordinate a test can move after handing out the closure that reads it.
@MainActor
private final class Spot {
    var coordinate: CLLocationCoordinate2D?
}

@Suite("Photo capture controller: Add Place")
struct PhotoCaptureControllerPlaceTests {
    @Test("a screen with no place anchor offers photographs and no Add Place")
    func noPlaceAnchorNoAddPlace() async throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        let controller = PhotoCaptureController()
        let places = FeedReader(controller.placeRequests())

        controller.attach(to: hike) { nil }
        controller.requestPlace()
        // Nothing can be sent afterwards to prove the absence against — this
        // screen has nowhere to put a place — so the reader is given the turns
        // it would have needed to drain a request that had gone.
        await settleDelegateHop()

        #expect(controller.isAvailable)
        #expect(controller.canAddPlace == false)
        #expect(places.received.isEmpty)
        #expect(controller.placeSpot() == nil)
    }

    @Test("a hike's screen offers Add Place, resolved at the tap rather than at attach")
    func placeSpotIsResolvedLate() async throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        let controller = PhotoCaptureController()
        let places = FeedReader(controller.placeRequests())
        let spot = Spot()

        controller.attach(to: hike, placeAnchor: { spot.coordinate }, anchor: { nil })
        #expect(controller.canAddPlace)
        // The route is still being built: nowhere to put one yet.
        #expect(controller.placeSpot() == nil)

        spot.coordinate = CLLocationCoordinate2D(latitude: 47.6, longitude: 12.9)
        controller.requestPlace()
        await settleDelegateHop(until: "the request to arrive") { !places.received.isEmpty }
        #expect(places.received.count == 1)
        let resolved = try #require(controller.placeSpot())
        #expect(resolved.hike.id == hike.id)
        #expect(resolved.coordinate.latitude == 47.6)
    }

    @Test("Add Place goes with the pill, and a place's own screen takes it away")
    func addPlaceFollowsThePill() async throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        let controller = PhotoCaptureController()
        let places = FeedReader(controller.placeRequests())
        let detail = controller.attach(to: hike, placeAnchor: { nil }, anchor: { nil })

        controller.setHostScreenPresent(false)
        #expect(controller.canAddPlace == false)
        controller.requestPlace()
        controller.setHostScreenPresent(true)
        #expect(controller.canAddPlace)
        // Proved against a request that does go. The two carry nothing to tell
        // them apart and a reader takes one per turn, so it is given the turns
        // to take a second before counting.
        controller.requestPlace()
        await settleDelegateHop(until: "the offered request to arrive") { !places.received.isEmpty }
        await settleDelegateHop()
        #expect(places.received.count == 1)

        // A place's screen claims the pill for its photographs only.
        let place = controller.attach(to: hike, place: UUID()) { nil }
        controller.detach(token: detail)
        #expect(controller.isAvailable)
        #expect(controller.canAddPlace == false)

        controller.detach(token: place)
        #expect(controller.isAvailable == false)
        #expect(controller.canAddPlace == false)
    }
}
