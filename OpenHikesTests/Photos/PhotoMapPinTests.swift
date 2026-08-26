//
//  PhotoMapPinTests.swift
//  OpenHikesTests
//
//  The two rules the map's photo pins encode, neither of which a view can be
//  trusted to reproduce: which photos become a pin at all, and which single
//  photo a place with several of them speaks with.
//
//  The second is the one worth pinning down. A point on the trail is one
//  target, so a pin has to pick a photo — and "the first one" has to mean the
//  same thing here as it does in the gallery strip and the viewer, or tapping
//  a pin opens a picture the user was not looking at.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import Testing

@Suite("Photo map pins")
struct PhotoMapPinTests {
    private static let bend = CLLocationCoordinate2D(latitude: 47.6301, longitude: 12.8802)
    private static let summit = CLLocationCoordinate2D(latitude: 47.6412, longitude: 12.8955)
    private static let start = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: Grouping

    @Test("a photo with no place on the trail draws no pin")
    func unanchoredPhotosAreNotDrawn() {
        let pins = PhotoMapPin.pins(for: [Self.photo(at: nil, offset: 0)])
        #expect(pins.isEmpty)
    }

    @Test("each anchored photo draws its own pin, in gallery order")
    func distinctPointsEachDrawAPin() {
        let first = Self.photo(at: Self.bend, offset: 0)
        let second = Self.photo(at: Self.summit, offset: 60)

        let pins = PhotoMapPin.pins(for: [first, second])

        #expect(pins.map(\.id) == [first.id, second.id])
        #expect(pins.allSatisfy { $0.count == 1 })
    }

    /// The rule the feature is specified in terms of: several photos at one
    /// point are one pin, and the pin is the first of them.
    @Test("photos sharing a point collapse onto the first of them")
    func sharedPointsCollapseOntoTheFirstPhoto() throws {
        let first = Self.photo(at: Self.bend, offset: 0)
        let second = Self.photo(at: Self.bend, offset: 60)
        let third = Self.photo(at: Self.bend, offset: 120)

        let pins = PhotoMapPin.pins(for: [first, second, third])

        let pin = try #require(pins.first)
        #expect(pins.count == 1)
        #expect(pin.photo.id == first.id)
        #expect(pin.count == 3)
    }

    /// A gallery is sorted by capture time, and the map has to inherit that
    /// order rather than whatever order the array happened to arrive in — a
    /// photo import can hand back several assets at once and out of order.
    @Test("the leading photo is the first one handed over, not the earliest id")
    func theLeaderFollowsGalleryOrder() throws {
        let earlier = Self.photo(at: Self.bend, offset: 0)
        let later = Self.photo(at: Self.bend, offset: 600)

        let pin = try #require(PhotoMapPin.pins(for: [earlier, later]).first)
        let reversed = try #require(PhotoMapPin.pins(for: [later, earlier]).first)

        #expect(pin.photo.id == earlier.id)
        #expect(reversed.photo.id == later.id)
    }

    @Test("an unanchored photo between two anchored ones is skipped, not shifted")
    func unanchoredPhotosDoNotDisplaceTheirNeighbours() {
        let first = Self.photo(at: Self.bend, offset: 0)
        let loose = Self.photo(at: nil, offset: 60)
        let second = Self.photo(at: Self.summit, offset: 120)

        let pins = PhotoMapPin.pins(for: [first, loose, second])

        #expect(pins.map(\.id) == [first.id, second.id])
    }

    @Test("a pin reports the coordinate its photo was anchored to")
    func pinsCarryTheirCoordinate() throws {
        let pin = try #require(
            PhotoMapPin.pins(for: [Self.photo(at: Self.summit, offset: 0)]).first
        )
        #expect(pin.coordinate.latitude == Self.summit.latitude)
        #expect(pin.coordinate.longitude == Self.summit.longitude)
    }

    // MARK: Controller

    @Test("a screen that attaches publishes its pins, and takes them with it")
    func attachingAndDetachingOwnsThePins() {
        let controller = PhotoMapPinController()
        let photo = Self.photo(at: Self.bend, offset: 0)

        let token = controller.attach([photo]) { _ in /* unused */ }
        #expect(controller.pins.map(\.id) == [photo.id])

        controller.detach(token: token)
        #expect(controller.pins.isEmpty)
    }

    /// SwiftUI presents the incoming screen before it tears the outgoing one
    /// down, so a release checked against anything but the token would clear
    /// the pins the replacement had already published.
    @Test("a stale screen cannot clear the pins that replaced its own")
    func aStaleTokenIsRefused() {
        let controller = PhotoMapPinController()
        let outgoing = controller.attach([Self.photo(at: Self.bend, offset: 0)]) { _ in /* unused */ }
        let incoming = Self.photo(at: Self.summit, offset: 60)
        controller.attach([incoming]) { _ in /* unused */ }

        controller.detach(token: outgoing)

        #expect(controller.pins.map(\.id) == [incoming.id])
    }

    @Test("a photo taken while the screen is up redraws its pins")
    func updatingRedrawsThePins() {
        let controller = PhotoMapPinController()
        let first = Self.photo(at: Self.bend, offset: 0)
        let token = controller.attach([first]) { _ in /* unused */ }

        let second = Self.photo(at: Self.summit, offset: 60)
        controller.update([first, second], token: token)

        #expect(controller.pins.count == 2)
        controller.update([], token: token + 1)
        #expect(controller.pins.count == 2, "a stale screen must not redraw the current one's pins")
    }

    /// The same guard ``RouteHighlight/move(to:)`` carries. A republish that
    /// changes nothing must not wake the map, because waking it drops and
    /// re-drops every marker on it.
    @Test("republishing the same pins notifies nobody")
    func anUnchangedRepublishIsSilent() async {
        let controller = PhotoMapPinController()
        let photo = Self.photo(at: Self.bend, offset: 0)
        let token = controller.attach([photo]) { _ in /* unused */ }
        let notifications = ObservationCounter { _ = controller.pins }

        // Denied first, then the change that must be heard. Waiting on the
        // positive effect is what makes the negative assertion mean something
        // — a bare sleep would only prove the machine was slow.
        controller.update([photo], token: token)
        controller.update([photo, Self.photo(at: Self.summit, offset: 60)], token: token)
        await settleDelegateHop(until: "the map to be told about the new pin") {
            notifications.count > 0
        }

        #expect(
            notifications.count == 1,
            "a republish of the same pins must not have woken the map"
        )
    }

    @Test("a tapped pin reaches the screen that published it")
    func openingReachesTheAttachedScreen() {
        let controller = PhotoMapPinController()
        let photo = Self.photo(at: Self.bend, offset: 0)
        var opened: [UUID] = []
        let token = controller.attach([photo]) { opened.append($0) }

        controller.open(photo.id)
        #expect(opened == [photo.id])

        // A tap that lands after the screen has gone has nowhere to push.
        controller.detach(token: token)
        controller.open(photo.id)
        #expect(opened == [photo.id])
    }

    // MARK: Navigating away

    /// The pins are claimed on `onAppear` and released on `onDisappear`, and
    /// SwiftUI runs a pop animation before the second of those — so without a
    /// separate signal the pins of a hike the user has navigated out of stay on
    /// the map, and stay tappable, for the whole transition.
    @Test("emptying the sheet's stack takes the pins off the map at once")
    func anEmptyStackClearsThePins() {
        let controller = PhotoMapPinController()
        let photo = Self.photo(at: Self.bend, offset: 0)
        var opened: [UUID] = []
        controller.attach([photo]) { opened.append($0) }

        controller.setHostScreenPresent(false)

        #expect(controller.pins.isEmpty)
        controller.open(photo.id)
        #expect(opened.isEmpty, "and a pin tapped on the way out pushes nothing")
    }

    /// Reported as the state of the path rather than as a pop, so the answer is
    /// recomputed rather than latched — a back-swipe the user abandons never
    /// disappears the screen that would have to re-publish.
    @Test("a back-swipe that is abandoned puts the pins back")
    func anAbandonedPopRestoresThePins() {
        let controller = PhotoMapPinController()
        let photo = Self.photo(at: Self.bend, offset: 0)
        controller.attach([photo]) { _ in /* unused */ }

        controller.setHostScreenPresent(false)
        controller.setHostScreenPresent(true)

        #expect(controller.pins.map(\.id) == [photo.id])
    }

    @Test("a screen that publishes while the stack is reported empty draws nothing")
    func aClaimCannotOverrideAnEmptyStack() {
        let controller = PhotoMapPinController()

        controller.setHostScreenPresent(false)
        let token = controller.attach([Self.photo(at: Self.bend, offset: 0)]) { _ in /* unused */ }
        controller.update([Self.photo(at: Self.summit, offset: 60)], token: token)

        #expect(controller.pins.isEmpty)
    }

    private static func photo(
        at coordinate: CLLocationCoordinate2D?,
        offset: TimeInterval
    ) -> HikePhoto {
        HikePhoto(
            capturedAt: start.addingTimeInterval(offset),
            coordinate: coordinate
        )
    }
}
