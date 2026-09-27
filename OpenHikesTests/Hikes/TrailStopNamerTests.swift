//
//  TrailStopNamerTests.swift
//  OpenHikesTests
//
//  The queue in front of the geocoder: who gets asked, how many at a time, and
//  who is never asked twice.
//
//  The policy half of reverse geocoding, and the only half that has rules worth
//  holding. ``TrailStopName`` next door decides what a single answer says;
//  this decides whether a question is asked at all — which is where the cost
//  is, because a hiker putting down five points in five seconds is five
//  questions and five at once from one phone is the burst that earns a rate
//  limit.
//

import CoreLocation
import MapKit
@testable import OpenHikes
import Testing

@MainActor
@Suite("Trail stop namer")
struct TrailStopNamerTests {
    /// A geocoder that answers when it is told to, and remembers everything it
    /// was asked.
    ///
    /// It holds each question open until `answer()` is called, which is what
    /// makes "one at a time" assertable at all: a stub that returned at once
    /// would let the reader empty the stream before anything could look at it.
    private final class Stub: TrailStopNaming {
        private(set) var asked: [CLLocationCoordinate2D] = []
        /// How many questions have come back, answered or refused — the one
        /// effect a refusal has that a test can wait on.
        private(set) var returned = 0
        /// What to answer with, in the order the questions arrive. `nil` is a
        /// refusal.
        var answers: [String?] = []

        private var waiting: [CheckedContinuation<Void, Never>] = []

        func mapItem(at coordinate: CLLocationCoordinate2D) async -> MKMapItem? {
            asked.append(coordinate)
            await withCheckedContinuation { continuation in
                waiting.append(continuation)
            }
            returned += 1
            guard !answers.isEmpty, let answer = answers.removeFirst() else { return nil }
            return MKMapItem(
                location: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude),
                address: MKAddress(fullAddress: answer, shortAddress: answer)
            )
        }

        /// Lets the question currently open return. Answers whether there was
        /// one.
        @discardableResult func answer() -> Bool {
            guard !waiting.isEmpty else { return false }
            waiting.removeFirst().resume()
            return true
        }

        /// How many questions are being held open right now.
        var open: Int { waiting.count }
    }

    private enum Ridge {
        static let longitude: Double = 12.86
        static let south: Double = 47.6300
        static let middle: Double = 47.6320
        static let north: Double = 47.6340
    }

    /// The names that reached the drawing, in order. A box rather than a
    /// captured `var`, because a settle condition reads it from a closure of
    /// its own.
    private final class Names {
        var all: [String] = []
    }

    private static func coordinate(_ latitude: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: Ridge.longitude)
    }

    private static func waypoints(_ latitudes: [Double]) -> [TrailWaypoint] {
        latitudes.map { TrailWaypoint(coordinate: coordinate($0)) }
    }

    /// Waits until the reader has put its `count`th question and is parked
    /// inside it.
    ///
    /// Waited on, not yielded for: a fixed number of `Task.yield()`s buys an
    /// amount of progress that depends on how busy the runner is, which is how
    /// this suite went red on CI in run 36301065320 while passing locally — see
    /// `SettleSupport.swift`. Parked is also what makes "the next one waits" an
    /// assertion rather than a race: the reader is serial, so while it is held
    /// inside a question it cannot start another.
    private func settleAsked(
        _ stub: Stub,
        _ count: Int,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        await settleDelegateHop(
            until: "the geocoder to have been asked \(count) time(s) and be holding one open",
            sourceLocation: sourceLocation
        ) {
            stub.asked.count == count && stub.open == 1
        }
    }

    /// Waits until `count` questions have come back to the reader.
    private func settleReturned(
        _ stub: Stub,
        _ count: Int,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        await settleDelegateHop(
            until: "\(count) question(s) to have come back",
            sourceLocation: sourceLocation
        ) {
            stub.returned == count
        }
    }

    @Test("a launch with no geocoder asks nothing and says so")
    func withoutASourceNothingIsAsked() {
        let namer = TrailStopNamer(source: nil)
        #expect(!namer.canAsk)

        // Refused before a reader could start, so there is nothing to wait
        // for: the absence of a crash and of a queue is the point, because
        // `nil` is the launch that must not ask.
        namer.nameUnnamed(in: Self.waypoints([Ridge.south, Ridge.north]))
        #expect(!namer.canAsk)
    }

    @Test("a point that already has a name is not asked about")
    func namedPointsAreSkipped() async {
        let stub = Stub()
        let namer = TrailStopNamer(source: stub)

        namer.nameUnnamed(in: [
            TrailWaypoint(coordinate: Self.coordinate(Ridge.south), name: "Lurdy Ház"),
        ])
        // Best effort only — there is no positive effect to wait on when the
        // right answer is that nothing happens.
        await settleDelegateHop()

        #expect(stub.asked.isEmpty)
    }

    /// The burst this queue exists to prevent.
    @Test("three points are three questions, asked one at a time")
    func questionsAreSerialised() async {
        let stub = Stub()
        stub.answers = ["One", "Two", "Three"]
        let namer = TrailStopNamer(source: stub)
        let named = Names()
        namer.onNamed { _, name in named.all.append(name) }

        namer.nameUnnamed(in: Self.waypoints([Ridge.south, Ridge.middle, Ridge.north]))
        await settleAsked(stub, 1)
        #expect(stub.asked.count == 1, "the second must wait for the first")

        stub.answer()
        await settleAsked(stub, 2)
        #expect(stub.asked.count == 2)

        stub.answer()
        await settleAsked(stub, 3)
        #expect(stub.asked.count == 3)

        stub.answer()
        await settleDelegateHop(until: "all three names to have landed") { named.all.count == 3 }
        #expect(named.all == ["One", "Two", "Three"])
    }

    @Test("asking again while a question is open does not ask it twice")
    func asecondPassDoesNotDuplicate() async {
        let stub = Stub()
        stub.answers = ["One", "Two"]
        let namer = TrailStopNamer(source: stub)
        let points = Self.waypoints([Ridge.south, Ridge.middle])

        namer.nameUnnamed(in: points)
        await settleAsked(stub, 1)
        // What every edit to the line does — see
        // ``TrailDraftController.commitLine()``.
        namer.nameUnnamed(in: points)
        namer.nameUnnamed(in: points)

        stub.answer()
        await settleAsked(stub, 2)
        stub.answer()
        await settleReturned(stub, 2)
        // A duplicate would be the reader's next question; give it the chance
        // to be asked before saying it was not.
        await settleDelegateHop()

        #expect(stub.asked.count == 2, "two points are two questions, however often it is asked")
        #expect(!stub.answer(), "and nothing is left open")
    }

    /// The same policy a refused leg has, and for the same reason: asking again
    /// on the next tap would spend a request per point to be told the same
    /// thing.
    @Test("a refusal is not retried by itself")
    func refusalsAreNotRetried() async {
        let stub = Stub()
        stub.answers = [nil]
        let namer = TrailStopNamer(source: stub)
        let points = Self.waypoints([Ridge.south])

        namer.nameUnnamed(in: points)
        await settleAsked(stub, 1)
        stub.answer()
        await settleReturned(stub, 1)

        // Settled before it was asked, so this call queues nothing at all.
        namer.nameUnnamed(in: points)

        #expect(stub.asked.count == 1)
    }

    /// A dragged stop keeps its id and loses its name, so a record kept by id
    /// alone left its row reading "Stop 2" for the rest of the drawing.
    @Test("a stop that moves is asked about again, where it now stands")
    func aMovedStopIsAskedAgain() async {
        let stub = Stub()
        stub.answers = ["Before", "After"]
        let namer = TrailStopNamer(source: stub)
        let named = Names()
        namer.onNamed { _, name in named.all.append(name) }
        let point = TrailWaypoint(coordinate: Self.coordinate(Ridge.south))

        namer.nameUnnamed(in: [point])
        await settleAsked(stub, 1)
        stub.answer()
        await settleDelegateHop(until: "the first name to have landed") { named.all.count == 1 }

        let moved = TrailWaypoint(coordinate: Self.coordinate(Ridge.north), id: point.id)
        namer.nameUnnamed(in: [moved])
        await settleAsked(stub, 2)
        stub.answer()
        await settleDelegateHop(until: "the moved stop's name to have landed") { named.all.count == 2 }

        #expect(stub.asked.map(\.latitude) == [Ridge.south, Ridge.north])
        #expect(named.all == ["Before", "After"])
    }

    /// End to end through the controller: the answer for where a stop *was*
    /// lands after it has been dragged, and must not name it; the stop is then
    /// asked about where it stands now.
    @Test("a dragged stop is named where it now stands, not where it was")
    func aDraggedStopIsNamedWhereItStands() async {
        let stub = Stub()
        stub.answers = ["Before", "After"]
        let maker = TrailDraftController(naming: stub)
        maker.setEditing(true)

        maker.appendWaypoint(at: Self.coordinate(Ridge.south))
        await settleAsked(stub, 1)
        #expect(stub.asked.count == 1)

        let id = maker.draft.waypoints[0].id
        maker.placeWaypoint(id, at: Self.coordinate(Ridge.north), named: "")
        stub.answer()
        // The stale answer is applied — or refused — in the same turn that
        // goes on to ask the next question, so by the second ask it has had
        // its chance to name the stop.
        await settleAsked(stub, 2)
        #expect(maker.draft.name(ofWaypointAt: 0).isEmpty, "the address of the spot it left")
        #expect(stub.asked.map(\.latitude) == [Ridge.south, Ridge.north])

        stub.answer()
        await settleDelegateHop(until: "the stop to be named where it now stands") {
            !maker.draft.name(ofWaypointAt: 0).isEmpty
        }
        #expect(maker.draft.name(ofWaypointAt: 0) == "After")
    }

    /// A reader cancelled by closing the maker can still be finishing its last
    /// request when the next one starts. It must neither answer for the new
    /// drawing nor leave the next call starting a second reader beside the
    /// running one — two lookups at once.
    @Test("a reader that was cleared cannot let a second one start beside the next")
    func aClearedDrainDoesNotDoubleTheNext() async {
        let stub = Stub()
        stub.answers = [nil, nil, nil]
        let namer = TrailStopNamer(source: stub)

        namer.nameUnnamed(in: Self.waypoints([Ridge.south]))
        await settleAsked(stub, 1)
        namer.clear()
        namer.nameUnnamed(in: Self.waypoints([Ridge.middle]))
        await settleDelegateHop(until: "the cleared question to be open beside the new one") {
            stub.asked.count == 2 && stub.open == 2
        }
        #expect(stub.asked.count == 2, "the cleared question is still open, and the new one has started")

        // The cleared reader's request comes back and that reader ends.
        stub.answer()
        await settleReturned(stub, 1)
        namer.nameUnnamed(in: Self.waypoints([Ridge.north]))
        // The live reader is parked inside the second question, so the only
        // way the third is asked now is by a second reader — give one the
        // chance to start before saying none did.
        await settleDelegateHop()

        #expect(stub.asked.count == 2, "the third must wait for the second")
        stub.answer()
        await settleAsked(stub, 3)
        #expect(stub.asked.map(\.latitude) == [Ridge.south, Ridge.middle, Ridge.north])
    }

    /// A hiker who closes the maker and comes back has plausibly moved, and one
    /// more attempt per point per opening is a bound they set with their thumb.
    @Test("closing the maker forgets what was asked, so reopening asks again")
    func clearingForgetsTheRecord() async {
        let stub = Stub()
        stub.answers = [nil, "Second time"]
        let namer = TrailStopNamer(source: stub)
        let points = Self.waypoints([Ridge.south])

        namer.nameUnnamed(in: points)
        await settleAsked(stub, 1)
        stub.answer()
        await settleReturned(stub, 1)

        namer.clear()
        namer.nameUnnamed(in: points)
        await settleAsked(stub, 2)

        #expect(stub.asked.count == 2)
    }
}
