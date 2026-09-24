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
    func noPlaceAnchorNoAddPlace() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        let controller = PhotoCaptureController()

        controller.attach(to: hike) { nil }
        controller.requestPlace()

        #expect(controller.isAvailable)
        #expect(controller.canAddPlace == false)
        #expect(controller.placeRequest == 0)
        #expect(controller.placeSpot() == nil)
    }

    @Test("a hike's screen offers Add Place, resolved at the tap rather than at attach")
    func placeSpotIsResolvedLate() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        let controller = PhotoCaptureController()
        let spot = Spot()

        controller.attach(to: hike, placeAnchor: { spot.coordinate }, anchor: { nil })
        #expect(controller.canAddPlace)
        // The route is still being built: nowhere to put one yet.
        #expect(controller.placeSpot() == nil)

        spot.coordinate = CLLocationCoordinate2D(latitude: 47.6, longitude: 12.9)
        controller.requestPlace()
        #expect(controller.placeRequest == 1)
        let resolved = try #require(controller.placeSpot())
        #expect(resolved.hike.id == hike.id)
        #expect(resolved.coordinate.latitude == 47.6)
    }

    @Test("Add Place goes with the pill, and a place's own screen takes it away")
    func addPlaceFollowsThePill() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        let controller = PhotoCaptureController()
        let detail = controller.attach(to: hike, placeAnchor: { nil }, anchor: { nil })

        controller.setHostScreenPresent(false)
        #expect(controller.canAddPlace == false)
        controller.requestPlace()
        #expect(controller.placeRequest == 0)
        controller.setHostScreenPresent(true)
        #expect(controller.canAddPlace)

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
