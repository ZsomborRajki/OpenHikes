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
    /// would drain the queue before anything could look at it.
    private final class Stub: TrailStopNaming {
        private(set) var asked: [CLLocationCoordinate2D] = []
        /// What to answer with, in the order the questions arrive. `nil` is a
        /// refusal.
        var answers: [String?] = []

        private var waiting: [CheckedContinuation<Void, Never>] = []

        func mapItem(at coordinate: CLLocationCoordinate2D) async -> MKMapItem? {
            asked.append(coordinate)
            await withCheckedContinuation { continuation in
                waiting.append(continuation)
            }
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
    }

    private enum Ridge {
        static let longitude: Double = 12.86
        static let south: Double = 47.6300
        static let middle: Double = 47.6320
        static let north: Double = 47.6340
    }

    private static func coordinate(_ latitude: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: Ridge.longitude)
    }

    private static func waypoints(_ latitudes: [Double]) -> [TrailWaypoint] {
        latitudes.map { TrailWaypoint(coordinate: coordinate($0)) }
    }

    /// Lets whatever the namer has started reach its first suspension point.
    ///
    /// Not a sleep: the drain is an unstructured `Task` on this same actor, so
    /// yielding is exactly the barrier that lets it run — the shape every other
    /// suite here waits on an effect with.
    private func settle() async {
        for _ in 0..<8 { await Task.yield() }
    }

    @Test("a launch with no geocoder asks nothing and says so")
    func withoutASourceNothingIsAsked() async {
        let namer = TrailStopNamer(source: nil)
        #expect(!namer.canAsk)

        namer.nameUnnamed(in: Self.waypoints([Ridge.south, Ridge.north]))
        await settle()
        // Nothing to assert against but the absence of a crash and of a
        // queue — which is the point: `nil` is the launch that must not ask.
        #expect(!namer.canAsk)
    }

    @Test("a point that already has a name is not asked about")
    func namedPointsAreSkipped() async {
        let stub = Stub()
        let namer = TrailStopNamer(source: stub)

        namer.nameUnnamed(in: [
            TrailWaypoint(coordinate: Self.coordinate(Ridge.south), name: "Lurdy Ház"),
        ])
        await settle()

        #expect(stub.asked.isEmpty)
    }

    /// The burst this queue exists to prevent.
    @Test("three points are three questions, asked one at a time")
    func questionsAreSerialised() async {
        let stub = Stub()
        stub.answers = ["One", "Two", "Three"]
        let namer = TrailStopNamer(source: stub)
        var named: [String] = []
        namer.onNamed { _, name in named.append(name) }

        namer.nameUnnamed(in: Self.waypoints([Ridge.south, Ridge.middle, Ridge.north]))
        await settle()

        #expect(stub.asked.count == 1, "the second must wait for the first")

        stub.answer()
        await settle()
        #expect(stub.asked.count == 2)

        stub.answer()
        await settle()
        #expect(stub.asked.count == 3)

        stub.answer()
        await settle()
        #expect(named == ["One", "Two", "Three"])
    }

    @Test("asking again while a question is open does not ask it twice")
    func asecondPassDoesNotDuplicate() async {
        let stub = Stub()
        stub.answers = ["One", "Two"]
        let namer = TrailStopNamer(source: stub)
        let points = Self.waypoints([Ridge.south, Ridge.middle])

        namer.nameUnnamed(in: points)
        await settle()
        // What every edit to the line does — see
        // ``TrailDraftController.commitLine()``.
        namer.nameUnnamed(in: points)
        namer.nameUnnamed(in: points)
        await settle()

        stub.answer()
        await settle()
        stub.answer()
        await settle()

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
        await settle()
        stub.answer()
        await settle()

        namer.nameUnnamed(in: points)
        await settle()

        #expect(stub.asked.count == 1)
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
        await settle()
        stub.answer()
        await settle()

        namer.clear()
        namer.nameUnnamed(in: points)
        await settle()

        #expect(stub.asked.count == 2)
    }
}
