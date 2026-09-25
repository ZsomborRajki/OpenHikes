//
//  HikeRouteInputTests.swift
//  OpenHikesDataTests
//
//  What a hike looks like off the main actor, and the one decision in it.
//
//  The widget's trail snapshot and the watch's trail package used to start
//  from two copies of this type with the same five fields, and they disagreed
//  about the name: the watch was sent the one the hiker had given the hike,
//  and the widget drew the one it was imported under. The name is what is
//  pinned here, because it is the field a copy can get wrong while still
//  compiling — and so is where it may be read from, because one of the three
//  reads it off the main actor.
//

import Foundation
@testable import OpenHikesData
import Testing

@Suite("Hike route input")
struct HikeRouteInputTests {
    @Test("a renamed hike is carried under the name the hiker gave it")
    func renamedHikeCarriesItsCustomName() {
        let hike = Hike(title: "Afternoon Walk", distanceMeters: 5200)
        hike.customName = "Jenner Ridge"
        #expect(HikeRouteInput(hike: hike).title == "Jenner Ridge")
    }

    @Test("a hike nobody renamed is carried under its own title")
    func unrenamedHikeCarriesItsTitle() {
        let hike = Hike(title: "Afternoon Walk", distanceMeters: 5200)
        #expect(HikeRouteInput(hike: hike).title == "Afternoon Walk")
    }

    @Test("the route and its figures are carried as the hike holds them")
    func carriesTheHikesValues() {
        let route = [
            RouteCoordinate(latitude: 47.55, longitude: 12.98),
            RouteCoordinate(latitude: 47.56, longitude: 12.99),
        ]
        let hike = Hike(title: "Loop", distanceMeters: 1350, tintHex: "#FF8800", route: route)
        let input = HikeRouteInput(hike: hike)
        #expect(input.hikeID == hike.id)
        #expect(input.tintHex == "#FF8800")
        #expect(input.totalDistanceMeters == 1350)
        #expect(input.route == route)
    }

    @Test("the input is read wherever the hike's context lives, not only on the main actor")
    func readsWithoutTheMainActor() {
        let hike = Hike(title: "Afternoon Walk", distanceMeters: 5200)
        hike.customName = "Jenner Ridge"
        #expect(Self.readWithoutIsolation(hike).title == "Jenner Ridge")
    }

    /// Compiles only while the initialiser and ``Hike/displayTitle`` are both
    /// nonisolated. The widget's background match builds one off the main
    /// actor, from a context it fetched the hike into there, and a main-actor
    /// initialiser called from that match is a Swift 6 error that
    /// `@preconcurrency` had quietly turned into a build warning.
    nonisolated private static func readWithoutIsolation(_ hike: Hike) -> HikeRouteInput {
        HikeRouteInput(hike: hike)
    }
}
