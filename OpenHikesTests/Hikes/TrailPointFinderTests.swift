//
//  TrailPointFinderTests.swift
//  OpenHikesTests
//
//  What a search hands the trail, and what a refusal does.
//
//  The ranking is the half of this feature that nothing on screen explains. A
//  search over one Alpine box answers with hundreds of places and forty are
//  added, so *which* forty is the whole of what the feature is worth — and it
//  is decided against the line the hiker is drawing rather than against the
//  middle of the screen, which is the reason this lives in the maker at all.
//
//  The other half is what happens when the answer does not arrive. Overpass
//  refuses ordinarily, so the rule is stated here rather than discovered: what
//  this device already knows about the area stands in, and the refusal is a
//  sentence beside it.
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

        func places(near _: CommunitySearchArea, showing _: Set<TrailPlaceSymbol>) async throws -> [TrailPlace] {
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

    /// What the finder handed over, one batch per answer.
    private final class Delivered {
        var batches: [[TrailPlace]] = []
        var names: [String] { batches.last?.map(\.name) ?? [] }
    }

    private static func delivering(_ finder: TrailPointFinder) -> Delivered {
        let delivered = Delivered()
        finder.onFound { delivered.batches.append($0) }
        return delivered
    }

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
        let delivered = Self.delivering(finder)

        Self.settled(finder)
        await Self.search(finder)

        #expect(!finder.isAvailable)
        #expect(delivered.batches.isEmpty, "and nothing was asked")
    }

    // MARK: - Which ones are added

    /// **The claim the feature rests on**, asserted on the ranking itself
    /// because it is only visible where there is more to offer than room: the
    /// line runs east along 47.60, the near place sits fifty metres off it,
    /// and the far one is two kilometres north — but the *map's centre* is
    /// nearer the far one, so a ranking against the screen would keep exactly
    /// the wrong one.
    @Test("what is added is what is nearest the line, not nearest the map")
    func placesAreRankedAgainstTheLine() {
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

    /// 578 pins is not a map. What is kept is chosen once, when the answer
    /// lands — see ``TrailPointRanking``.
    @Test("no more than the ceiling of results is ever added")
    func onlyTheNearestFewAreAdded() async {
        let many = (0..<(TrailPointQuery.maximumResults + 20)).map { index in
            Self.place(47.60 + Double(index) / 10_000, 12.92)
        }
        let finder = Self.finder(answering: many)
        let delivered = Self.delivering(finder)

        Self.settled(finder)
        await Self.search(finder, along: Self.line)

        #expect(delivered.batches.last?.count == TrailPointQuery.maximumResults)
    }

    /// Without this a second search over the same valley would put a second
    /// pin on the spring the first one found.
    @Test("a place already on the trail is not added again")
    func aPlaceAlreadyOnTheTrailIsNotAdded() async {
        let placed = Self.place(47.6005, 12.92, name: "The spring")
        // The same spring a few metres off, as a second mapping has it.
        let same = Self.place(47.6006, 12.9201)
        let elsewhere = Self.place(47.6005, 12.93, name: "Elsewhere")
        let finder = Self.finder(answering: [same, elsewhere])
        let delivered = Self.delivering(finder)

        Self.settled(finder)
        await Self.search(finder, along: Self.line, avoiding: [placed])

        #expect(delivered.names == ["Elsewhere"])
    }

    // MARK: - The maker's switches

    /// The switches reach the request: a source is told which kinds to ask
    /// for, and a kind switched off is not among them.
    @Test("a search asks only for the kinds switched on")
    func aSearchAsksForTheKindsSwitchedOn() async {
        let source = StubRecordingSource()
        let filter = TrailPlaceFilter(defaults: nil)
        filter.setShows(false, .shelter)
        filter.setShows(false, .parking)
        let finder = TrailPointFinder(source: source, filter: filter)

        Self.settled(finder)
        await Self.search(finder, along: Self.line)

        #expect(source.askedFor == [[.summit, .water, .viewpoint, .camp]])
    }

    /// **The pin never goes on the map**, whichever way it arrives: from an
    /// answer that carried it anyway — a summit asked for as a viewpoint is
    /// still a summit — or from what the disk kept from before the switch.
    @Test("a kind switched off is never added, from an answer or from the disk")
    func aSwitchedOffKindIsNeverAdded() async {
        let hut = Self.place(47.6005, 12.92, name: "Hut", symbol: .shelter)
        let spring = Self.place(47.6005, 12.93, name: "Spring", symbol: .water)

        let answering = TrailPointFinder(source: StubPointSource { [hut, spring] })
        answering.filter.setShows(false, .shelter)
        let fromAnswer = Self.delivering(answering)
        Self.settled(answering)
        await Self.search(answering, along: Self.line)

        let refusing = TrailPointFinder(source: StubStoringSource(stored: [hut, spring]))
        refusing.filter.setShows(false, .shelter)
        let fromDisk = Self.delivering(refusing)
        Self.settled(refusing)
        await Self.search(refusing, along: Self.line)

        #expect(fromAnswer.names == ["Spring"])
        #expect(fromDisk.names == ["Spring"])
    }

    /// A switch turned off takes its pins off the map at once; a search that
    /// was already out and lands a moment later must not put them back.
    @Test("a kind switched off while a search is out is not added when it lands")
    func aKindSwitchedOffMidSearchIsNotAdded() async {
        let (gate, open) = AsyncStream<Void>.makeStream()
        let hut = Self.place(47.6005, 12.92, name: "Hut", symbol: .shelter)
        let spring = Self.place(47.6005, 12.93, name: "Spring", symbol: .water)
        let finder = TrailPointFinder(source: StubPointSource {
            for await _ in gate { break }
            return [hut, spring]
        })
        let delivered = Self.delivering(finder)
        Self.settled(finder)

        finder.search(along: Self.line, avoiding: [])
        #expect(finder.isSearching)
        finder.filter.setShows(false, .shelter)
        open.yield()
        while finder.isSearching {
            await Task.yield()
        }

        #expect(delivered.names == ["Spring"])
    }

    /// Every switch off leaves nothing to ask for, so the pill cannot be tapped
    /// — the state it already takes for a map zoomed out too far.
    @Test("with every kind switched off the pill cannot be tapped")
    func everyKindOffDisablesThePill() {
        let finder = Self.finder(answering: [])
        Self.settled(finder)

        for symbol in TrailPointQuery.searchableSymbols {
            finder.filter.setShows(false, symbol)
        }
        #expect(!finder.canSearch)

        finder.filter.setShows(true, .water)
        #expect(finder.canSearch)
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
        let delivered = Self.delivering(finder)

        Self.settled(finder)
        await Self.search(finder, along: Self.line)

        #expect(finder.notice == nil)
        #expect(delivered.batches.count == 1)
    }

    /// **What a refusal adds instead of nothing.** Three of five first
    /// attempts came back `504` the day this was measured, and the valley may
    /// well have answered an hour ago — so the places already on this device
    /// are added, and the caption still says the search failed.
    @Test("a refused search adds what is already on this device, and still says it failed")
    func aRefusalAddsWhatIsStored() async {
        let stored = Self.place(47.6005, 12.92, name: "Kalte Quelle")
        let finder = TrailPointFinder(source: StubStoringSource(stored: [stored]))
        let delivered = Self.delivering(finder)

        Self.settled(finder)
        await Self.search(finder, along: Self.line)

        #expect(delivered.names == ["Kalte Quelle"])
        #expect(finder.notice == .outage(.busy), "it is still a refusal and still says so")
        #expect(finder.notice?.caption.isWarning == true)
    }

    /// **Nothing here may ever block drawing**: a refusal after an answer adds
    /// nothing new and takes nothing away — what the first search added is on
    /// the trail, not in the finder.
    @Test("a refusal after an answer only reports")
    func aRefusalAfterAnAnswerOnlyReports() async {
        let stub = StubRefusingAfterOneAnswer(place: Self.place(47.6005, 12.92, name: "Spring"))
        let finder = TrailPointFinder(source: stub)
        let delivered = Self.delivering(finder)

        Self.settled(finder)
        await Self.search(finder, along: Self.line)
        #expect(delivered.names == ["Spring"])

        await Self.search(finder, along: Self.line)

        #expect(delivered.batches.last?.isEmpty == true, "nothing on this device to add")
        #expect(finder.notice == .outage(.busy))
    }

    /// A search that answered adds its answer and nothing else: the store is
    /// the failure path and only the failure path.
    @Test("a search that answered never reads the disk")
    func anAnsweredSearchIgnoresTheDisk() async {
        let stored = Self.place(47.6005, 12.93, name: "From the disk")
        let found = Self.place(47.6005, 12.92, name: "From Overpass")
        let source = StubStoringSource(stored: [stored], answeringFirst: [found], alwaysAnswers: true)
        let finder = TrailPointFinder(source: source)
        let delivered = Self.delivering(finder)

        Self.settled(finder)
        await Self.search(finder, along: Self.line)

        #expect(delivered.names == ["From Overpass"])
        #expect(source.diskReads == 0)
    }

    /// A superseded search is not a refusal. Reporting one would put a warning
    /// under the pill because the hiker closed the maker.
    @Test("a cancelled search reports and adds nothing")
    func aCancelledSearchReportsNothing() async {
        let finder = Self.finder(refusing: CancellationError())
        let delivered = Self.delivering(finder)

        Self.settled(finder)
        await Self.search(finder)

        #expect(finder.notice == nil)
        #expect(delivered.batches.isEmpty)
    }

    @Test("closing the maker forgets the caption")
    func clearingForgetsTheCaption() async {
        let finder = Self.finder(answering: [])

        Self.settled(finder)
        await Self.search(finder)
        #expect(finder.notice != nil)

        finder.clear()

        #expect(finder.notice == nil)
        #expect(!finder.isSearching)
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

    func places(near _: CommunitySearchArea, showing _: Set<TrailPlaceSymbol>) throws -> [TrailPlace] {
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

    func places(near _: CommunitySearchArea, showing _: Set<TrailPlaceSymbol>) throws -> [TrailPlace] {
        guard answered.takeFirst() else {
            throw TrailGraphProviderError.server(statusCode: Self.gatewayTimeout)
        }
        return [place]
    }
}

/// Answers nothing and remembers which kinds each search asked for.
private struct StubRecordingSource: TrailPointSourcing {
    private let calls = Calls()

    var askedFor: [[TrailPlaceSymbol]] { calls.asked }

    /// A reference box, because the conformance is `Sendable` and the record
    /// is the point of the stub.
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var value: [[TrailPlaceSymbol]] = []

        var asked: [[TrailPlaceSymbol]] { lock.withLock { value } }

        func record(_ symbols: Set<TrailPlaceSymbol>) {
            // In the order the switches are drawn, so the assertion can be a
            // literal rather than a set.
            lock.withLock { value.append(TrailPointQuery.searchableSymbols.filter(symbols.contains)) }
        }
    }

    func places(near _: CommunitySearchArea, showing symbols: Set<TrailPlaceSymbol>) -> [TrailPlace] {
        calls.record(symbols)
        return []
    }
}
