//
//  ScreenClaimsTests.swift
//  OpenHikesTests
//
//  Whose claim on the map is in force when several of the sheet's screens
//  have made one: the deepest, then the newest — and a pop hands it back to
//  the claim beneath without anybody re-claiming.
//
//  The controllers that keep their claims this way are checked through it
//  too, with the order SwiftUI was measured producing three screens deep: the
//  screen two levels down appears again *after* the one just pushed.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import Testing

@MainActor
@Suite("Screen claims")
struct ScreenClaimsTests {
    @Test("the deepest claim is in force, whatever order they arrive in")
    func deepestWins() {
        var claims = ScreenClaims<String>()
        let place = claims.attach("place", depth: 3)
        claims.attach("hike again", depth: 1)

        #expect(claims.active?.payload == "place")
        #expect(claims.active?.token == place)
    }

    @Test("between claims at one depth the newer is in force, as it always was")
    func newestWinsAtOneDepth() {
        var claims = ScreenClaims<String>()
        claims.attach("leaving", depth: 1)
        claims.attach("arriving", depth: 1)

        #expect(claims.active?.payload == "arriving")
    }

    @Test("withdrawing the claim in force hands it to the one beneath")
    func popHandsBack() {
        var claims = ScreenClaims<String>()
        claims.attach("hike", depth: 1)
        let place = claims.attach("place", depth: 2)

        claims.detach(place)
        #expect(claims.active?.payload == "hike")
        claims.detach(place)
        #expect(claims.active?.payload == "hike", "a token withdrawn twice changes nothing the second time")
    }

    @Test("an update reaches only a claim still standing")
    func updateNeedsAStandingClaim() {
        var claims = ScreenClaims<String>()
        let token = claims.attach("before", depth: 1)

        #expect(claims.update(token) { $0 = "after" })
        claims.detach(token)
        #expect(!claims.update(token) { $0 = "late" })
        #expect(claims.active == nil)
    }

    // MARK: Through the controllers

    @Test("a place screen keeps its pins and placeholder when the hike beneath appears again")
    func placePinsSurviveAReappearingHike() {
        let controller = TrailPlacePinController()
        let hikeRow = TrailPlaceRow(place: TrailPlace(latitude: 47.6, longitude: 12.9, name: "Hut"))
        let pending = TrailPlaceRow(place: TrailPlace(latitude: 47.61, longitude: 12.9, symbol: .viewpoint))

        controller.attach([hikeRow], depth: 1)
        let adder = controller.attach([hikeRow], placeholder: pending, depth: 3)
        controller.attach([hikeRow], depth: 1)

        #expect(controller.placeholderID == pending.id)
        #expect(controller.rows.map(\.id) == [hikeRow.id, pending.id])

        controller.detach(token: adder)
        #expect(controller.placeholderID == nil)
        #expect(controller.rows.map(\.id) == [hikeRow.id])
    }

    @Test("a photograph from the pill is filed under the place when the hike beneath appears again")
    func cameraPillKeepsThePlace() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        let placeID = UUID()
        let controller = PhotoCaptureController()

        controller.attach(to: hike, depth: 1) { nil }
        let place = controller.attach(to: hike, place: placeID, depth: 3) { nil }
        controller.attach(to: hike, depth: 1) { nil }

        #expect(controller.currentSubject()?.placeID == placeID)
        controller.detach(token: place)
        #expect(controller.currentSubject()?.placeID == nil)
        #expect(controller.isAvailable)
    }
}
