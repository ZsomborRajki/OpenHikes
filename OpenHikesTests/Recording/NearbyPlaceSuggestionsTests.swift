//
//  NearbyPlaceSuggestionsTests.swift
//  OpenHikesTests
//
//  What the recording screen's *Add Place* offers from OpenStreetMap: what is
//  within reach of where the hiker stands, nearest first, and nothing the
//  walk already has.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import Testing

@MainActor
@Suite("Nearby place suggestions")
struct NearbyPlaceSuggestionsTests {
    private static let here = CLLocationCoordinate2D(latitude: 47.61, longitude: 12.98)

    private static func place(_ id: Int64, metresNorth: Double) -> TrailPlace {
        TrailPlace(
            latitude: here.latitude + metresNorth / RouteGeometry.metersPerDegreeLatitude,
            longitude: here.longitude,
            symbol: .shelter,
            osm: TrailPlaceOSM(elementType: "node", elementID: id)
        )
    }

    @Test("what is within reach is offered, nearest first")
    func nearestFirstWithinReach() {
        let near = Self.place(1, metresNorth: 20)
        let nearer = Self.place(2, metresNorth: 5)
        let far = Self.place(3, metresNorth: NearbyPlaceSuggestions.matchRadiusMeters + 50)

        let offered = NearbyPlaceSuggestions.suggestions(from: [near, far, nearer], around: Self.here, excluding: [])

        #expect(offered.map(\.osm?.elementID) == [2, 1])
    }

    @Test("an element the walk already has is not offered again, but its neighbour is")
    func heldElementIsLeftOut() {
        let hut = Self.place(1, metresNorth: 10)
        let spring = Self.place(2, metresNorth: 12)

        let offered = NearbyPlaceSuggestions.suggestions(from: [hut, spring], around: Self.here, excluding: [hut])

        #expect(offered.map(\.osm?.elementID) == [2])
    }

    @Test("one element answered twice is offered once, and a place with no element is not a suggestion")
    func duplicatesAndHandMadeAreLeftOut() {
        let hut = Self.place(1, metresNorth: 10)
        let handMade = TrailPlace(coordinate: Self.here, name: "Mine")

        let offered = NearbyPlaceSuggestions.suggestions(from: [hut, hut, handMade], around: Self.here, excluding: [])

        #expect(offered.count == 1)
    }

    // MARK: The finder

    @Test("the live answer replaces what the device had")
    func liveAnswerReplacesStored() async {
        let stored = Self.place(1, metresNorth: 10)
        let live = Self.place(2, metresNorth: 12)
        let finder = NearbyPlaceFinder()

        let source = NearbySource(stored: [stored], live: [live], refuses: false)
        await finder.start(around: Self.here, excluding: [], from: source).value

        #expect(finder.suggestions.map(\.osm?.elementID) == [2])
        #expect(finder.outage == nil)
    }

    @Test("a refused search leaves what the device had, and says why")
    func refusalKeepsStored() async {
        let stored = Self.place(1, metresNorth: 10)
        let finder = NearbyPlaceFinder()

        let source = NearbySource(stored: [stored], live: [], refuses: true)
        await finder.start(around: Self.here, excluding: [], from: source).value

        #expect(finder.suggestions.map(\.osm?.elementID) == [1])
        #expect(finder.outage != nil)
    }

    @Test("the list is short")
    func listIsCapped() {
        let many = (1...20).map { Self.place(Int64($0), metresNorth: Double($0)) }
        let offered = NearbyPlaceSuggestions.suggestions(from: many, around: Self.here, excluding: [])
        #expect(offered.count == NearbyPlaceSuggestions.maximumSuggestions)
    }
}

/// Answers from the device with `stored`, and from the network with `live` —
/// or refuses, as a busy Overpass does.
private struct NearbySource: TrailPointSourcing {
    let stored: [TrailPlace]
    let live: [TrailPlace]
    let refuses: Bool

    /// What a gateway in front of a busy Overpass answers with.
    private static let gatewayTimeout = 504

    func places(near _: CommunitySearchArea, showing _: Set<TrailPlaceSymbol>) throws -> [TrailPlace] {
        guard !refuses else { throw TrailGraphProviderError.server(statusCode: Self.gatewayTimeout) }
        return live
    }

    func cachedPlaces(near _: CommunitySearchArea, limit _: Int) -> [TrailPlace] {
        stored
    }
}
