//
//  HikePlacesAroundSearchTests.swift
//  OpenHikesTests
//
//  *Places Around Trail*: what one search finds, what the list and the map
//  show of it as the hiker narrows and widens the choice, and what adding does.
//
//  The promise under test is that the line is asked about once and filtered
//  many times — narrowing *Within* or switching a kind off asks nothing — and
//  that what the hike holds is left out of the offer by the hike as it is now,
//  not as it was when the search went out.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import SwiftData
import Testing

@MainActor
@Suite("Places around a trail")
struct HikePlacesAroundSearchTests {
    private enum Line {
        static let longitude = 12.98
        static let south = 47.60
        static let north = 47.62
        static let route = [
            RouteCoordinate(latitude: south, longitude: longitude),
            RouteCoordinate(latitude: north, longitude: longitude),
        ]
    }

    private static func place(
        _ id: Int64,
        latitude: Double,
        offEast meters: Double = 0,
        symbol: TrailPlaceSymbol = .water
    ) -> TrailPlace {
        let degrees = meters / (RouteGeometry.metersPerDegreeLatitude * cos(latitude * .pi / 180))
        return TrailPlace(
            latitude: latitude,
            longitude: Line.longitude + degrees,
            symbol: symbol,
            osm: TrailPlaceOSM(elementType: "node", elementID: id)
        )
    }

    private static let spring = place(1, latitude: 47.605)
    private static let hut = place(2, latitude: 47.61, offEast: 400, symbol: .shelter)
    private static let summit = place(3, latitude: 47.615, offEast: 800, symbol: .summit)
    private static let everything = Set(TrailPlaceSymbol.allCases)

    private static func searched(_ answer: [TrailPlace] = [spring, hut, summit]) async -> HikePlacesAroundSearch {
        let search = HikePlacesAroundSearch()
        await search.search(along: Line.route, from: AnsweringSource(answer: answer), showing: everything).value
        return search
    }

    // MARK: Filtering what was found

    @Test("the widest reach offers everything within a kilometre, in walking order")
    func widestReachOffersEverything() async {
        let search = await Self.searched()

        let offered = search.candidates(showing: Self.everything, held: [])

        #expect(search.phase == .found)
        #expect(offered.map(\.place.osm?.elementID) == [1, 2, 3])
    }

    @Test("narrowing the reach filters what was found and asks nothing")
    func narrowingAsksNothing() async {
        let search = await Self.searched()

        search.reach = .nearby
        #expect(search.candidates(showing: Self.everything, held: []).map(\.place.osm?.elementID) == [1, 2])
        search.reach = .onTrail
        #expect(search.candidates(showing: Self.everything, held: []).map(\.place.osm?.elementID) == [1])
        #expect(!search.needsSearch(showing: Self.everything))
    }

    @Test("widening past what was asked, or a kind the request left out, asks again")
    func wideningAsksAgain() async {
        let search = HikePlacesAroundSearch()
        search.reach = .nearby
        await search.search(along: Line.route, from: AnsweringSource(answer: []), showing: [.water]).value

        search.reach = .around
        #expect(search.needsSearch(showing: [.water]))
        search.reach = .onTrail
        #expect(!search.needsSearch(showing: [.water]))
        #expect(search.needsSearch(showing: [.water, .summit]))
    }

    /// A turn of the phone builds the screen again on the same search, and
    /// the new screen asks whether to search as it comes up, possibly while
    /// the old screen's request is still out. Checked before the request's
    /// task can run: this suite holds the main actor until it awaits.
    @Test("a request still out counts as asked, until it is cancelled")
    func requestOutCountsAsAsked() async {
        let search = HikePlacesAroundSearch()
        let out = search.search(along: Line.route, from: AnsweringSource(answer: [Self.spring]), showing: [.water])

        #expect(!search.needsSearch(showing: [.water]), "a screen coming up waits for the answer")
        search.reach = .nearby
        #expect(!search.needsSearch(showing: [.water]), "and so does a narrower reach")
        #expect(search.needsSearch(showing: [.water, .summit]), "a kind the request leaves out is asked for")

        search.cancel()
        #expect(search.needsSearch(showing: [.water]), "a cancelled request is asked again")
        await out.value
        #expect(search.found.isEmpty, "and its answer lands nowhere")
    }

    @Test("a kind switched off is left out of the offer")
    func switchedOffKindIsLeftOut() async {
        let search = await Self.searched()

        let offered = search.candidates(showing: [.water, .summit], held: [])

        #expect(offered.map(\.place.osm?.elementID) == [1, 3])
    }

    @Test("what the hike holds now is left out, and offered again once it is removed")
    func heldIsLeftOutByTheHikeAsItIs() async {
        let search = await Self.searched()

        #expect(search.candidates(showing: Self.everything, held: [Self.hut]).map(\.place.osm?.elementID) == [1, 3])
        #expect(search.candidates(showing: Self.everything, held: []).map(\.place.osm?.elementID) == [1, 2, 3])
    }

    // MARK: Search This Area

    @Test("a place found by Search This Area is offered whatever the reach")
    func askedAboutPlacesIgnoreTheReach() async {
        let search = await Self.searched([Self.spring])
        let farSummit = Self.place(9, latitude: 47.61, offEast: 3000, symbol: .summit)

        await search.receiveArea([farSummit], along: Line.route).value
        search.reach = .onTrail

        #expect(search.candidates(showing: Self.everything, held: []).map(\.place.osm?.elementID) == [1, 9])
    }

    @Test("an area answering for a place the line already found does not list it twice")
    func areaAndLineShareOneRowPerElement() async {
        let search = await Self.searched([Self.spring, Self.hut])
        let sameHut = Self.place(2, latitude: 47.61, offEast: 400, symbol: .shelter)

        await search.receiveArea([sameHut], along: Line.route).value
        search.reach = .onTrail

        #expect(search.found.count == 2)
        #expect(search.candidates(showing: Self.everything, held: []).map(\.place.osm?.elementID) == [1, 2])
    }

    // MARK: Merging answers

    private static func row(_ place: TrailPlace) -> TrailPlaceRow {
        TrailPlaceRow(place: place, offRouteMeters: 0)
    }

    private static func receive(_ places: [TrailPlace], into search: HikePlacesAroundSearch) {
        search.receive(.init(rows: places.map(row), outage: nil), reach: 1000, symbols: everything)
    }

    @Test("an answer repeated, in any order, adds nothing and keeps the first answer's order")
    func repeatedAnswerKeepsTheOrder() {
        let search = HikePlacesAroundSearch()

        Self.receive([Self.spring, Self.hut, Self.summit], into: search)
        Self.receive([Self.summit, Self.hut, Self.spring], into: search)

        #expect(search.found.map(\.id) == [Self.spring.id, Self.hut.id, Self.summit.id])
    }

    @Test("a later answer appends only what is new, after what was found")
    func laterAnswerAppends() {
        let search = HikePlacesAroundSearch()
        let pond = Self.place(4, latitude: 47.618)

        Self.receive([Self.hut, Self.spring], into: search)
        Self.receive([pond, Self.spring, Self.summit], into: search)

        #expect(search.found.map(\.place.osm?.elementID) == [2, 1, 4, 3])
    }

    @Test("the same element under another id keeps the first row's id, from the line or an area")
    func sameElementKeepsTheFirstID() async {
        let search = HikePlacesAroundSearch()
        let sameSpring = Self.place(1, latitude: 47.605)
        let sameHut = Self.place(2, latitude: 47.61, offEast: 400, symbol: .shelter)

        Self.receive([Self.spring, sameSpring, Self.hut], into: search)
        await search.receiveArea([sameHut], along: Line.route).value

        #expect(search.found.map(\.id) == [Self.spring.id, Self.hut.id])
        #expect(search.askedAbout == [Self.hut.id], "the area's hut stands for the row already found")
        #expect(search.row(sameHut.id) == nil)
        #expect(search.row(Self.hut.id)?.place.osm?.elementID == 2)
    }

    @Test("a place with no element is one row per id")
    func placeWithoutAnElementIsKeptByID() {
        let search = HikePlacesAroundSearch()
        let bench = TrailPlace(latitude: 47.607, longitude: Line.longitude, name: "Bench")
        let rock = TrailPlace(latitude: 47.607, longitude: Line.longitude, name: "Bench")

        Self.receive([bench, rock], into: search)
        Self.receive([rock, bench], into: search)

        #expect(search.found.map(\.id) == [bench.id, rock.id])
    }

    // MARK: Refusals

    @Test("a refusal with nothing found is a failure, and with something found a caption")
    func refusals() {
        let search = HikePlacesAroundSearch()

        search.receive(.init(rows: [], outage: .busy), reach: 1000, symbols: Self.everything)
        #expect(search.phase == .failed(.busy))

        search.receive(
            .init(rows: [TrailPlaceRow(place: Self.spring, offRouteMeters: 0)], outage: .busy),
            reach: 1000,
            symbols: Self.everything
        )
        #expect(search.phase == .found)
        #expect(search.outage == .busy)
        #expect(search.needsSearch(showing: Self.everything), "a refused answer is asked again")
    }

    // MARK: Adding

    @Test("adding puts one found place on the hike, saved, and keeps its card open")
    func addingSavesOnePlace() async throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, route: Line.route)
        let search = await Self.searched()
        search.selection = Self.hut.id

        let added = try search.add(Self.hut.id, to: hike, in: context)

        #expect(added)
        #expect(hike.places.map(\.osm?.elementID) == [2])
        #expect(search.selection == Self.hut.id, "the card stays up, now the card of a place the hike has")
        let reopened = ModelContext(context.container)
        #expect(try reopened.fetch(FetchDescriptor<TrailPoint>()).map(\.id) == [Self.hut.id])
    }

    @Test("a refused save leaves the hike as it was, and adding again commits it once")
    func refusedAddCanBeRetried() async throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, route: Line.route)
        try context.save()
        let search = await Self.searched()
        let saver = ScriptedModelContextSaver(failedSaveNumbers: [1])

        #expect(throws: HikePlaceRefusal.notAdded) {
            try search.add(Self.spring.id, to: hike, in: context, save: saver.save)
        }
        #expect(hike.places.isEmpty)

        #expect(try search.add(Self.spring.id, to: hike, in: context, save: saver.save))
        let reopened = ModelContext(context.container)
        #expect(try reopened.fetch(FetchDescriptor<TrailPoint>()).map(\.id) == [Self.spring.id])
    }

    // MARK: The list

    @Test("the list puts what the line passes first and the rest under Nearby, each in walking order")
    func listingSplitsAndOrders() {
        let heldSpring = TrailPlaceRow(
            place: Self.spring,
            anchor: TrailPlaceAnchor(distanceAlongRouteMeters: 600, offRouteMeters: 0)
        )
        let nearHut = TrailPlaceRow(
            place: Self.hut,
            anchor: TrailPlaceAnchor(distanceAlongRouteMeters: 1100, offRouteMeters: 400)
        )
        let farSummit = TrailPlaceRow(place: Self.summit, anchor: nil, offRouteMeters: 800)
        let lateSpring = TrailPlaceRow(
            place: Self.place(4, latitude: 47.618),
            anchor: TrailPlaceAnchor(distanceAlongRouteMeters: 2000, offRouteMeters: 10)
        )

        let listing = TrailPlaceAroundListing(held: [heldSpring], candidates: [farSummit, lateSpring, nearHut])

        #expect(listing.onTrail.map(\.id) == [Self.spring.id, lateSpring.id])
        #expect(listing.onTrail.map(\.isAdded) == [true, false])
        #expect(listing.nearby.map(\.id) == [Self.hut.id, Self.summit.id])
    }

    /// The sort compares the walking position alone and leaves a tie to
    /// `sorted(by:)` being stable, so this is what holds a tie in place.
    @Test("places at the same point keep the order they came in, the hike's own first")
    func listingKeepsTiesInArrivalOrder() {
        let onTheLine = TrailPlaceAnchor(distanceAlongRouteMeters: 600, offRouteMeters: 0)
        let heldSpring = TrailPlaceRow(place: Self.spring, anchor: onTheLine)
        let foundTwin = TrailPlaceRow(place: Self.place(5, latitude: 47.605), anchor: onTheLine)
        let firstAway = TrailPlaceRow(place: Self.place(6, latitude: 47.61), anchor: nil, offRouteMeters: 800)
        let secondAway = TrailPlaceRow(place: Self.place(7, latitude: 47.61), anchor: nil, offRouteMeters: 800)
        let thirdAway = TrailPlaceRow(place: Self.place(8, latitude: 47.61), anchor: nil, offRouteMeters: 800)

        let listing = TrailPlaceAroundListing(
            held: [heldSpring],
            candidates: [firstAway, foundTwin, secondAway, thirdAway]
        )

        #expect(listing.onTrail.map(\.id) == [heldSpring.id, foundTwin.id])
        #expect(listing.onTrail.map(\.isAdded) == [true, false])
        #expect(listing.nearby.map(\.id) == [firstAway.id, secondAway.id, thirdAway.id])
    }
}

private struct AnsweringSource: TrailPointSourcing {
    let answer: [TrailPlace]

    func places(near _: CommunitySearchArea, showing symbols: Set<TrailPlaceSymbol>) -> [TrailPlace] {
        answer.filter { $0.symbol.map(symbols.contains) ?? true }
    }
}
