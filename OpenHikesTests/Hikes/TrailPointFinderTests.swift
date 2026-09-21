//
//  TrailPointFinderTests.swift
//  OpenHikesTests
//
//  What is offered, in what order, and what a refusal does to what was already
//  on offer.
//
//  The ranking is the half of this phase that nothing on screen explains. A
//  search over one Alpine box answers with hundreds of places and forty are
//  drawn, so *which* forty is the whole of what the feature is worth — and it
//  is decided against the line the hiker is drawing rather than against the
//  middle of the screen, which is the reason this lives in the maker at all.
//
//  The other half is what happens when the answer does not arrive. Overpass
//  refuses ordinarily, so the rule is stated here rather than discovered: the
//  candidates already on offer stay, because they are still true, and the
//  refusal is a sentence beside them.
//

import CoreLocation
import Foundation
import MapKit
@testable import OpenHikes
import Testing

@MainActor
@Suite("Trail point finder")
struct TrailPointFinderTests {
    /// A source that answers whatever it was built with, without a network.
    private struct StubPointSource: TrailPointSourcing {
        let answer: @Sendable () async throws -> [TrailPlace]

        func places(near _: CommunitySearchArea) async throws -> [TrailPlace] {
            try await answer()
        }
    }

    private static let centre = CLLocationCoordinate2D(latitude: 47.60, longitude: 12.90)

    private static func finder(answering places: [TrailPlace]) -> TrailPointFinder {
        TrailPointFinder(source: StubPointSource { places })
    }

    private static func finder(refusing error: any Error) -> TrailPointFinder {
        TrailPointFinder(source: StubPointSource { throw error })
    }

    /// A region small enough to be searchable, centred where the fixtures are.
    private static func settled(
        _ finder: TrailPointFinder,
        at coordinate: CLLocationCoordinate2D = centre,
        spanDegrees: Double = 0.05
    ) {
        finder.regionDidSettle(
            MKCoordinateRegion(
                center: coordinate,
                span: MKCoordinateSpan(latitudeDelta: spanDegrees, longitudeDelta: spanDegrees)
            )
        )
    }

    private static func place(
        _ latitude: Double,
        _ longitude: Double,
        name: String = "",
        symbol: TrailPlaceSymbol? = .water
    ) -> TrailPlace {
        TrailPlace(latitude: latitude, longitude: longitude, name: name, symbol: symbol)
    }

    /// A short line running east along 47.60, which everything below is ranked
    /// against.
    private static let line = [
        RouteCoordinate(latitude: 47.60, longitude: 12.90),
        RouteCoordinate(latitude: 47.60, longitude: 12.94),
    ]

    private static func search(
        _ finder: TrailPointFinder,
        along route: [RouteCoordinate] = [],
        avoiding placed: [TrailPlace] = []
    ) async {
        finder.search(along: route, avoiding: placed)
        while finder.isSearching {
            await Task.yield()
        }
    }

    // MARK: - What a tap would ask

    /// The ceiling is the one state the pill is disabled in rather than
    /// withdrawn, and this is what it reads.
    @Test("a map zoomed past the ceiling has nothing to ask about")
    func aWideMapHasNothingToAsk() {
        let finder = Self.finder(answering: [])

        Self.settled(finder)
        #expect(finder.searchableArea != nil)
        #expect(finder.canSearch)

        Self.settled(finder, spanDegrees: 2)
        #expect(finder.searchableArea == nil, "a map this wide asks nothing")
        #expect(!finder.canSearch)
    }

    /// A launch with no source withdraws the pill rather than offering a
    /// button that cannot answer — the shape `canSnapToPaths` already takes
    /// for a launch with no trail graph.
    @Test("a launch with no source is not available")
    func aLaunchWithNoSourceIsNotAvailable() async {
        let finder = TrailPointFinder()

        Self.settled(finder)
        await Self.search(finder)

        #expect(!finder.isAvailable)
        #expect(finder.rows.isEmpty, "and nothing was asked")
    }

    // MARK: - Which ones are offered

    /// **The claim the feature rests on**, asserted on the ranking itself
    /// because it is only visible where there is more to offer than room: the
    /// line runs east along 47.60, the near place sits fifty metres off it,
    /// and the far one is two kilometres north — but the *map's centre* is
    /// nearer the far one, so a ranking against the screen would keep exactly
    /// the wrong one.
    @Test("what is offered is what is nearest the line, not nearest the map")
    func candidatesAreRankedAgainstTheLine() {
        let near = Self.place(47.6005, 12.92, name: "Near the path")
        let far = Self.place(47.62, 12.90, name: "Off in the woods")

        let chosen = TrailPointRanking.chosen(
            from: [far, near],
            along: Self.line,
            around: CLLocationCoordinate2D(latitude: 47.615, longitude: 12.90),
            limit: 1
        )

        #expect(chosen.map(\.name) == ["Near the path"])
    }

    /// What is *offered* is ranked against the line; what is **listed** is in
    /// the order the line meets it, which is ``TrailPlaceOrder``'s rule and
    /// the same one the marked places follow. A place too far off the line to
    /// be described by it still sorts by where it passes, and simply carries
    /// no figure.
    @Test("what is offered is listed in the order the line meets it")
    func candidatesAreListedAlongTheLine() async {
        let early = Self.place(47.6005, 12.905, name: "Early")
        let late = Self.place(47.6005, 12.935, name: "Late")
        let aside = Self.place(47.62, 12.92, name: "Two kilometres north")
        let finder = Self.finder(answering: [late, aside, early])

        Self.settled(finder)
        await Self.search(finder, along: Self.line)

        #expect(finder.rows.map(\.place.name) == ["Early", "Two kilometres north", "Late"])
        #expect(finder.rows.first?.anchor != nil, "it is on the walk and says where")
        #expect(
            finder.rows[1].anchor == nil,
            "and this one is not, so it says nothing rather than something wrong"
        )
    }

    /// A perfectly ordinary thing to do: marking the hut before drawing the
    /// walk to it is the most useful order to work in, and there is no line to
    /// rank against then.
    @Test("with nothing drawn, what is offered is what is nearest the map")
    func candidatesFallBackToTheMapCentre() async {
        let close = Self.place(47.601, 12.901, name: "Close")
        let distant = Self.place(47.65, 12.95, name: "Distant")
        let finder = Self.finder(answering: [distant, close])

        Self.settled(finder)
        await Self.search(finder)

        #expect(finder.rows.map(\.place.name) == ["Distant", "Close"], "unordered without a line")
        #expect(finder.rows.allSatisfy { $0.anchor == nil }, "and nothing can be placed along one")
    }

    /// 578 pins is not a map. What is kept is chosen once, when the answer
    /// lands — see ``TrailPointRanking``.
    @Test("no more than the ceiling of results is ever offered")
    func onlyTheNearestFewAreOffered() async {
        let many = (0..<(TrailPointQuery.maximumResults + 20)).map { index in
            Self.place(47.60 + Double(index) / 10_000, 12.92)
        }
        let finder = Self.finder(answering: many)

        Self.settled(finder)
        await Self.search(finder, along: Self.line)

        #expect(finder.rows.count == TrailPointQuery.maximumResults)
    }

    /// Without this a hiker sees their own hut with a second, provisional pin
    /// under it, offering to add the hut again.
    @Test("a place the hiker has already marked is not offered again")
    func anAlreadyMarkedPlaceIsNotOffered() async {
        let marked = Self.place(47.6005, 12.92, name: "The spring")
        // The same spring as OpenStreetMap has it: a few metres off, because
        // the hiker marked it by tapping the map.
        let same = Self.place(47.6006, 12.9201)
        let elsewhere = Self.place(47.6005, 12.93)
        let finder = Self.finder(answering: [same, elsewhere])

        Self.settled(finder)
        await Self.search(finder, along: Self.line, avoiding: [marked])

        #expect(finder.rows.count == 1)
        #expect(finder.rows.first?.place.longitude == 12.93)
    }

    // MARK: - What it says for itself

    /// An area with nothing in it is an *answer* and must not wear the warning
    /// glyph: nothing is broken, and looking somewhere else is what to do.
    @Test("an empty area says empty rather than unavailable")
    func anEmptyAreaSaysEmpty() async {
        let finder = Self.finder(answering: [])

        Self.settled(finder)
        await Self.search(finder)

        #expect(finder.notice == .nothingHere)
        #expect(finder.notice?.caption.isWarning == false)
    }

    /// Places arriving is the answer nobody needs a sentence about: they are
    /// on the map, which is where a hiker reads them.
    @Test("places arriving say nothing at all")
    func placesArrivingSayNothing() async {
        let finder = Self.finder(answering: [Self.place(47.6005, 12.92)])

        Self.settled(finder)
        await Self.search(finder, along: Self.line)

        #expect(finder.notice == nil)
    }

    /// **Nothing here may ever block drawing**, and this is the sharpest form
    /// of it: a refusal about the request that was going to replace the
    /// candidates must not take the candidates away.
    @Test("a refusal is reported beside what was already offered")
    func aRefusalKeepsWhatWasOffered() async {
        let stub = StubRefusingAfterOneAnswer(place: Self.place(47.6005, 12.92, name: "Spring"))
        let finder = TrailPointFinder(source: stub)

        Self.settled(finder)
        await Self.search(finder, along: Self.line)
        #expect(finder.rows.count == 1)

        await Self.search(finder, along: Self.line)

        #expect(finder.rows.count == 1, "the spring is still there and still true")
        #expect(finder.notice == .outage(.busy))
        #expect(finder.notice?.caption.isWarning == true, "and this one *is* a failure")
    }

    /// **What a refusal draws instead of an empty map.** Three of five first
    /// attempts came back `504` the day this was measured, and the valley may
    /// well have answered an hour ago — so the places already on this device
    /// go down as candidates, and the caption still says the search failed.
    @Test("a refused search draws what is already on this device, and still says it failed")
    func aRefusalDrawsWhatIsStored() async {
        let stored = Self.place(47.6005, 12.92, name: "Kalte Quelle")
        let finder = TrailPointFinder(source: StubStoringSource(stored: [stored]))

        Self.settled(finder)
        await Self.search(finder, along: Self.line)

        #expect(finder.rows.map(\.place.name) == ["Kalte Quelle"])
        #expect(finder.notice == .outage(.busy), "it is still a refusal and still says so")
        #expect(finder.notice?.caption.isWarning == true)
    }

    /// And the disk is not touched at all when there is already something on
    /// offer, because a refusal never replaces candidates that are still true
    /// — so reading every file in the cache directory would buy nothing.
    @Test("a refusal with candidates already offered does not read the disk")
    func aRefusalKeepsTheOfferAndReadsNothing() async {
        let offered = Self.place(47.6005, 12.92, name: "Spring")
        let stored = Self.place(47.6005, 12.93, name: "From the disk")
        let source = StubStoringSource(stored: [stored], answeringFirst: [offered])
        let finder = TrailPointFinder(source: source)

        Self.settled(finder)
        await Self.search(finder, along: Self.line)
        await Self.search(finder, along: Self.line)

        #expect(finder.rows.map(\.place.name) == ["Spring"])
        #expect(source.diskReads == 0, "nothing on the disk could have improved on this")
    }

    /// A search that answered draws its answer and nothing else: the store is
    /// the failure path and only the failure path.
    @Test("a search that answered never draws from the disk")
    func anAnsweredSearchIgnoresTheDisk() async {
        let stored = Self.place(47.6005, 12.93, name: "From the disk")
        let found = Self.place(47.6005, 12.92, name: "From Overpass")
        let source = StubStoringSource(stored: [stored], answeringFirst: [found], alwaysAnswers: true)
        let finder = TrailPointFinder(source: source)

        Self.settled(finder)
        await Self.search(finder, along: Self.line)

        #expect(finder.rows.map(\.place.name) == ["From Overpass"])
        #expect(source.diskReads == 0)
    }

    /// A superseded search is not a refusal. Reporting one would put a warning
    /// under the pill because the hiker closed the maker.
    @Test("a cancelled search reports nothing")
    func aCancelledSearchReportsNothing() async {
        let finder = Self.finder(refusing: CancellationError())

        Self.settled(finder)
        await Self.search(finder)

        #expect(finder.notice == nil)
    }

    // MARK: - Taking one

    /// Taking a candidate takes its pin: a marked place's own pin arrives in
    /// its place, and two pins on one spot is what this stops.
    @Test("a candidate that is taken stops being offered")
    func takingACandidateRemovesIt() async throws {
        let finder = Self.finder(answering: [
            Self.place(47.6005, 12.92, name: "One"),
            Self.place(47.6005, 12.93, name: "Two"),
        ])

        Self.settled(finder)
        await Self.search(finder, along: Self.line)

        finder.take(try #require(finder.rows.first?.id))

        #expect(finder.rows.map(\.place.name) == ["Two"])
    }

    /// Nothing on offer is the hiker's, so nothing survives the screen it was
    /// offered on.
    @Test("closing the maker forgets everything")
    func clearingForgetsEverything() async {
        let finder = Self.finder(answering: [])

        Self.settled(finder)
        await Self.search(finder)
        #expect(finder.notice != nil)

        finder.clear()

        #expect(finder.rows.isEmpty)
        #expect(finder.notice == nil)
    }

    /// A leg that finds a path moves every distance without the hiker having
    /// touched anything, so the labels have to follow the line rather than the
    /// search that found them.
    @Test("a line that changes shape re-places what is on offer")
    func aChangedLineRePlacesTheOffer() async throws {
        let finder = Self.finder(answering: [Self.place(47.6005, 12.93, name: "Spring")])

        Self.settled(finder)
        await Self.search(finder, along: Self.line)
        let before = finder.rows.first?.anchor?.distanceAlongRouteMeters

        // The same walk, started a kilometre further west: everything on it is
        // now further along.
        finder.rerank(along: [
            RouteCoordinate(latitude: 47.60, longitude: 12.88),
            RouteCoordinate(latitude: 47.60, longitude: 12.94),
        ])

        let after = try #require(finder.rows.first?.anchor?.distanceAlongRouteMeters)
        #expect(after > (try #require(before)))
    }
}

/// A source that refuses over the wire and has something on disk.
///
/// The two halves are what the fall-back is about, and they cannot be written
/// as a closure over a constant: what is asserted is which of them the finder
/// reached, and how often.
private struct StubStoringSource: TrailPointSourcing {
    let stored: [TrailPlace]
    /// What the first search answers with, if anything. An empty list refuses
    /// straight away, which is the case a cold valley meets.
    var answeringFirst: [TrailPlace] = []
    /// Whether every search answers, rather than only the first.
    var alwaysAnswers = false

    private let calls = Calls()

    /// What a gateway in front of a busy Overpass answers with, measured.
    private static let gatewayTimeout = 504

    /// How many times the disk was asked. `0` is the assertion in two of the
    /// three cases.
    var diskReads: Int { calls.diskReads }

    /// A reference box, because the conformance is `Sendable` and a count is
    /// the point of the stub.
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var searches = 0
        private var reads = 0

        var diskReads: Int { lock.withLock { reads } }

        func search() -> Int { lock.withLock { searches += 1; return searches } }
        func read() { lock.withLock { reads += 1 } }
    }

    func places(near _: CommunitySearchArea) throws -> [TrailPlace] {
        let call = calls.search()
        guard alwaysAnswers || (call == 1 && !answeringFirst.isEmpty) else {
            throw TrailGraphProviderError.server(statusCode: Self.gatewayTimeout)
        }
        return answeringFirst
    }

    func cachedPlaces(near _: CommunitySearchArea, limit _: Int) -> [TrailPlace] {
        calls.read()
        return stored
    }
}

/// Answers once and refuses afterwards, which is the sequence the case about a
/// refusal needs and the only one that cannot be written as a closure over a
/// constant.
private struct StubRefusingAfterOneAnswer: TrailPointSourcing {
    let place: TrailPlace
    private let answered = Answered()

    /// A reference box, because the conformance is `Sendable` and the sequence
    /// is the point of the stub.
    private final class Answered: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        func takeFirst() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !value else { return false }
            value = true
            return true
        }
    }

    /// What a gateway in front of a busy Overpass answers with, measured.
    private static let gatewayTimeout = 504

    func places(near _: CommunitySearchArea) throws -> [TrailPlace] {
        guard answered.takeFirst() else {
            throw TrailGraphProviderError.server(statusCode: Self.gatewayTimeout)
        }
        return [place]
    }
}
