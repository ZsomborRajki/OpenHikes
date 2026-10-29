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
import OpenHikesData
import Testing

@MainActor
@Suite("Nearby place suggestions")
struct NearbyPlaceSuggestionsTests {
    private static let here = CLLocationCoordinate2D(latitude: 47.61, longitude: 12.98)

    private static func place(
        _ id: Int64,
        metersNorth: Double,
        type: String = "node",
        name: String = "",
        facts: [TrailPlaceFact] = []
    ) -> TrailPlace {
        TrailPlace(
            latitude: here.latitude + metersNorth / RouteGeometry.metersPerDegreeLatitude,
            longitude: here.longitude,
            name: name,
            symbol: .shelter,
            osm: TrailPlaceOSM(elementType: type, elementID: id, facts: facts)
        )
    }

    @Test("what is within reach is offered, nearest first")
    func nearestFirstWithinReach() {
        let near = Self.place(1, metersNorth: 20)
        let nearer = Self.place(2, metersNorth: 5)
        let far = Self.place(3, metersNorth: NearbyPlaceSuggestions.matchRadiusMeters + 50)

        let offered = NearbyPlaceSuggestions.suggestions(from: [near, far, nearer], around: Self.here, excluding: [])

        #expect(offered.map(\.osm?.elementID) == [2, 1])
    }

    @Test("an element the walk already has is not offered again, but its neighbour is")
    func heldElementIsLeftOut() {
        let hut = Self.place(1, metersNorth: 10)
        let spring = Self.place(2, metersNorth: 12)

        let offered = NearbyPlaceSuggestions.suggestions(from: [hut, spring], around: Self.here, excluding: [hut])

        #expect(offered.map(\.osm?.elementID) == [2])
    }

    @Test("one element answered twice is offered once, and a place with no element is not a suggestion")
    func duplicatesAndHandMadeAreLeftOut() {
        let hut = Self.place(1, metersNorth: 10)
        let handMade = TrailPlace(coordinate: Self.here, name: "Mine")

        let offered = NearbyPlaceSuggestions.suggestions(from: [hut, hut, handMade], around: Self.here, excluding: [])

        #expect(offered.count == 1)
    }

    // MARK: One of each element

    /// The copy kept is the first answered, not the nearest: keeping the
    /// nearer repeats would offer A before C.
    @Test("repeats keep the first answer for each element")
    func repeatsKeepFirstAnswer() {
        let found = [
            Self.place(1, metersNorth: 30, name: "A"),
            Self.place(2, metersNorth: 10, name: "B"),
            Self.place(1, metersNorth: 5, name: "A again"),
            Self.place(3, metersNorth: 20, name: "C"),
            Self.place(2, metersNorth: 1, name: "B again"),
        ]

        let offered = NearbyPlaceSuggestions.suggestions(from: found, around: Self.here, excluding: [])

        #expect(offered.map(\.name) == ["B", "C", "A"])
    }

    /// An element is claimed before its distance is measured, so a first
    /// answer out of reach is not followed by a second chance from a later
    /// copy. This pins the order of the checks: a nearer copy winning would be
    /// a decision of its own, not a side effect of how the list is filtered.
    @Test("an element's first answer is the one measured, even out of reach")
    func firstAnswerOutOfReachClaimsTheElement() {
        let found = [
            Self.place(1, metersNorth: NearbyPlaceSuggestions.matchRadiusMeters + 50, name: "Far"),
            Self.place(1, metersNorth: 10, name: "Near"),
            Self.place(2, metersNorth: 20, name: "Other"),
        ]

        let offered = NearbyPlaceSuggestions.suggestions(from: found, around: Self.here, excluding: [])

        #expect(offered.map(\.name) == ["Other"])
    }

    @Test("a node and a way with the same number are two elements")
    func elementTypeIsPartOfTheElement() {
        let node = Self.place(7, metersNorth: 10, type: "node", name: "Node")
        let way = Self.place(7, metersNorth: 12, type: "way", name: "Way")
        let relation = Self.place(7, metersNorth: 14, type: "relation", name: "Relation")

        let offered = NearbyPlaceSuggestions.suggestions(
            from: [node, way, relation],
            around: Self.here,
            excluding: [Self.place(7, metersNorth: 0, type: "way")]
        )

        #expect(offered.map(\.name) == ["Node", "Relation"])
    }

    /// An element is its type and number, not what the map says about it. The
    /// walk's copy of the hut was read when it was marked, and the map may say
    /// more about the hut today; a repeat that says more is still a repeat.
    @Test("what the map says about an element does not make it another one")
    func factsAreNotPartOfTheElement() {
        let water = [TrailPlaceFact(kind: .drinkingWater, value: "yes")]
        let marked = Self.place(1, metersNorth: 10, name: "Hut")
        let found = [
            Self.place(1, metersNorth: 10, name: "Hut", facts: water),
            Self.place(2, metersNorth: 12, name: "Spring"),
            Self.place(2, metersNorth: 12, name: "Spring again", facts: water),
        ]

        let offered = NearbyPlaceSuggestions.suggestions(from: found, around: Self.here, excluding: [marked])

        #expect(offered.map(\.name) == ["Spring"])
    }

    /// The hut and its spring mapped on the same spot are two things to
    /// choose from, offered in the order they were answered.
    @Test("two elements at one spot are both offered, in the order answered")
    func samePositionIsNotSameElement() {
        let hut = Self.place(1, metersNorth: 10, name: "Hut")
        let spring = Self.place(2, metersNorth: 10, name: "Spring")

        let offered = NearbyPlaceSuggestions.suggestions(from: [hut, spring], around: Self.here, excluding: [])
        let reversed = NearbyPlaceSuggestions.suggestions(from: [spring, hut], around: Self.here, excluding: [])

        #expect(offered.map(\.name) == ["Hut", "Spring"])
        #expect(reversed.map(\.name) == ["Spring", "Hut"])
    }

    /// Equally near, the first answered are offered and the rest are cut,
    /// whatever their numbers.
    @Test("among equally near elements, the first answered make the list")
    func equallyNearKeepAnswerOrder() {
        let found = (1...12).reversed().map { Self.place(Int64($0), metersNorth: 10) }

        let offered = NearbyPlaceSuggestions.suggestions(from: found, around: Self.here, excluding: [])

        #expect(offered.compactMap(\.osm?.elementID) == Array((5...12).reversed()))
    }

    @Test("repeats do not use up the short list")
    func repeatsDoNotSpendTheCap() {
        let repeats = Array(repeating: Self.place(1, metersNorth: 1), count: 20)
        let others = (2...20).map { Self.place(Int64($0), metersNorth: Double($0)) }

        let offered = NearbyPlaceSuggestions.suggestions(from: repeats + others, around: Self.here, excluding: [])

        #expect(offered.compactMap(\.osm?.elementID) == Array(1...Int64(NearbyPlaceSuggestions.maximumSuggestions)))
    }

    /// What the walk already has is left out before the list is cut, so
    /// holding the nearest few still leaves a full list of the rest.
    @Test("held elements do not use up the short list")
    func heldElementsDoNotSpendTheCap() {
        let held = (1...3).map { Self.place(Int64($0), metersNorth: Double($0)) }
        let others = (4...20).map { Self.place(Int64($0), metersNorth: Double($0)) }
        let cap = Int64(NearbyPlaceSuggestions.maximumSuggestions)

        let offered = NearbyPlaceSuggestions.suggestions(from: held + others, around: Self.here, excluding: held)

        #expect(offered.compactMap(\.osm?.elementID) == Array(4...(3 + cap)))
    }

    // MARK: The finder

    @Test("the live answer replaces what the device had")
    func liveAnswerReplacesStored() async {
        let stored = Self.place(1, metersNorth: 10)
        let live = Self.place(2, metersNorth: 12)
        let finder = NearbyPlaceFinder()

        let source = NearbySource(stored: [stored], live: [live], refuses: false)
        await finder.start(around: Self.here, excluding: [], from: source).value

        #expect(finder.suggestions.map(\.osm?.elementID) == [2])
        #expect(finder.outage == nil)
    }

    @Test("a refused search leaves what the device had, and says why")
    func refusalKeepsStored() async {
        let stored = Self.place(1, metersNorth: 10)
        let finder = NearbyPlaceFinder()

        let source = NearbySource(stored: [stored], live: [], refuses: true)
        await finder.start(around: Self.here, excluding: [], from: source).value

        #expect(finder.suggestions.map(\.osm?.elementID) == [1])
        #expect(finder.outage != nil)
    }

    @Test("the list is short")
    func listIsCapped() {
        let many = (1...20).map { Self.place(Int64($0), metersNorth: Double($0)) }
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
