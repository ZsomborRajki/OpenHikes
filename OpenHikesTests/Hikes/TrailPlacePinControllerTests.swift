//
//  TrailPlacePinControllerTests.swift
//  OpenHikesTests
//
//  Who a saved hike's place pin belongs to, and so what a tap on it opens.
//
//  A pin opens its place through the screen that drew it: the claim carries
//  the opener as it carries the rows. What these defend is the handover —
//  SwiftUI presents the incoming screen before it tears the outgoing one
//  down, so a pin must open through the newest claim, and never through a
//  screen that has gone or while no screen is up at all.
//
//  And the hiker's switch beside the *Places* heading: off takes the pins away
//  without touching the claim underneath, and is remembered.
//

import Foundation
@testable import OpenHikes
import Testing

@MainActor
@Suite("Place pin claims")
struct TrailPlacePinControllerTests {
    private static let spring = TrailPlaceRow(
        place: TrailPlace(latitude: 47.61, longitude: 12.98, symbol: .water),
        anchor: nil
    )
    private static let hut = TrailPlaceRow(
        place: TrailPlace(latitude: 47.62, longitude: 12.98, symbol: .shelter),
        anchor: nil
    )

    @Test("a pin opens through the newest claim, not the one it replaced")
    func newestClaimOpens() {
        let controller = TrailPlacePinController()
        var detail: [UUID] = []
        var place: [UUID] = []
        let outgoing = controller.attach([Self.spring]) { detail.append($0) }
        controller.attach([Self.spring]) { place.append($0) }

        controller.detach(token: outgoing)

        #expect(controller.open(Self.spring.id))
        #expect(detail.isEmpty)
        #expect(place == [Self.spring.id])
    }

    @Test("an update from the claiming screen redraws, and one from a replaced screen does not")
    func updatesFollowTheClaim() {
        let controller = TrailPlacePinController()
        let outgoing = controller.attach([Self.spring])
        let incoming = controller.attach([Self.spring])

        controller.update([Self.spring, Self.hut], token: outgoing)
        #expect(controller.rows.count == 1)

        controller.update([Self.spring, Self.hut], token: incoming)
        #expect(controller.rows.count == 2)
    }

    @Test("with no screen pushed, pins are off the map and open nothing")
    func noHostOpensNothing() {
        let controller = TrailPlacePinController()
        var opened = 0
        controller.attach([Self.spring]) { _ in opened += 1 }

        controller.setHostScreenPresent(false)

        #expect(controller.rows.isEmpty)
        #expect(controller.open(Self.spring.id) == false)
        controller.setHostScreenPresent(true)
        #expect(controller.open(Self.spring.id))
        #expect(opened == 1)
    }

    @Test("a place that is not on the map opens nothing")
    func unknownPlaceOpensNothing() {
        let controller = TrailPlacePinController()
        controller.attach([Self.spring]) { _ in Issue.record("nothing should open") }

        #expect(controller.open(Self.hut.id) == false)
    }

    // MARK: - The show-places switch

    @Test("switching places off hides the pins and keeps the claim, so on redraws them")
    func switchHidesWithoutWithdrawing() {
        let controller = TrailPlacePinController()
        var opened = 0
        let token = controller.attach([Self.spring]) { _ in opened += 1 }

        controller.setShowsPins(false)
        #expect(controller.rows.isEmpty)
        #expect(controller.open(Self.spring.id) == false)

        // A place arriving while hidden is still taken, and drawn on the way back.
        controller.update([Self.spring, Self.hut], token: token)
        #expect(controller.rows.isEmpty)
        controller.setShowsPins(true)
        #expect(controller.rows.count == 2)
        #expect(controller.open(Self.spring.id))
        #expect(opened == 1)
    }

    @Test("the switch starts on and is remembered off")
    func switchIsRemembered() throws {
        let defaults = try #require(UserDefaults(suiteName: "TrailPlacePinControllerTests-\(UUID().uuidString)"))
        #expect(TrailPlacePinController(defaults: defaults).showsPins)

        TrailPlacePinController(defaults: defaults).setShowsPins(false)
        let next = TrailPlacePinController(defaults: defaults)
        #expect(next.showsPins == false)
        next.attach([Self.spring])
        #expect(next.rows.isEmpty)
    }
}
