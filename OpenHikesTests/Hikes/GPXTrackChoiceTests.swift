//
//  GPXTrackChoiceTests.swift
//  OpenHikesTests
//
//  The question a multi-track file asks, and its answers.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import Testing

@MainActor
@Suite("GPX track choice")
struct GPXTrackChoiceTests {
    private static func tracks(_ names: [String?]) -> [GPXImport.Track] {
        names.enumerated().map { index, name in
            GPXImport.Track(
                name: name,
                trackDescription: nil,
                author: nil,
                keywords: nil,
                startTime: nil,
                segments: [Self.points(from: 47 + Double(index))]
            )
        }
    }

    private static func points(from latitude: Double) -> [GPXImport.Point] {
        [latitude, latitude + 0.001].map { lat in
            GPXImport.Point(coordinate: .init(latitude: lat, longitude: 12), elevation: nil, time: nil)
        }
    }

    /// Waits for the question to be on screen, which is what a tap needs.
    private func asked(_ choice: GPXTrackChoice) async {
        await settleDelegateHop(until: "the question to be put up") { choice.question != nil }
    }

    @Test("every track starts ticked, and Import answers with the ticked ones")
    func importAnswersTheTicked() async {
        let choice = GPXTrackChoice()
        let tracks = Self.tracks(["Mon", nil, "Wed"])
        async let answer = choice.ask(fileName: "week.gpx", tracks: tracks, unplacedWaypoints: 2)
        await asked(choice)

        #expect(choice.question?.options.map(\.title) == ["Mon", "Track 2", "Wed"])
        #expect(choice.question?.chosenCount == 3)
        #expect(choice.question?.unplacedWaypoints == 2)
        choice.toggle(1)
        choice.confirm()

        #expect(await answer == [0, 2])
        #expect(choice.question == nil)
    }

    @Test("Cancel answers with none")
    func cancelAnswersNone() async {
        let choice = GPXTrackChoice()
        async let answer = choice.ask(fileName: "week.gpx", tracks: Self.tracks(["Mon", "Tue"]), unplacedWaypoints: 0)
        await asked(choice)
        choice.cancel()

        #expect(await answer.isEmpty)
    }

    /// Two files opened together ask together, and "none" deletes an inbox
    /// copy — so the second must wait rather than answer the first for it.
    @Test("a second question waits for the first to be answered")
    func aSecondQuestionWaits() async {
        let choice = GPXTrackChoice()
        async let first = choice.ask(fileName: "a.gpx", tracks: Self.tracks(["A", "B"]), unplacedWaypoints: 0)
        await asked(choice)
        async let second = choice.ask(fileName: "b.gpx", tracks: Self.tracks(["C", "D"]), unplacedWaypoints: 0)
        // A third, so the turn is seen to be handed down a queue rather than
        // to whoever asked last. The two start concurrently, so which of them
        // is second is not the test's to fix — only that each gets its turn.
        async let third = choice.ask(fileName: "c.gpx", tracks: Self.tracks(["E"]), unplacedWaypoints: 0)

        await settleDelegateHop(until: "both to queue behind the first") { choice.waitingCount == 2 }

        #expect(choice.question?.fileName == "a.gpx", "the first stays up")
        choice.toggle(0)
        choice.confirm()
        #expect(await first == [1])

        var answered: Set<String> = []
        for _ in 0..<2 {
            await settleDelegateHop(until: "the next question") {
                choice.question.map { !answered.contains($0.fileName) } ?? false
            }
            answered.insert(choice.question?.fileName ?? "")
            choice.confirm()
        }
        #expect(answered == ["b.gpx", "c.gpx"])
        #expect(await second == [0, 1])
        #expect(await third == [0])
        #expect(choice.question == nil)
    }

    /// Each queued caller is resumed once, in turn, and once the queue has
    /// drained the next caller is asked straight away rather than parked
    /// behind a turn nobody holds. A continuation resumed twice traps, so the
    /// stray answers at the end are what "exactly once" is checked by.
    @Test("a drained queue hands the turn back free")
    func aDrainedQueueFreesTheTurn() async {
        let choice = GPXTrackChoice()
        async let first = choice.ask(fileName: "a.gpx", tracks: Self.tracks(["A"]), unplacedWaypoints: 0)
        await asked(choice)
        async let second = choice.ask(fileName: "b.gpx", tracks: Self.tracks(["B"]), unplacedWaypoints: 0)
        async let third = choice.ask(fileName: "c.gpx", tracks: Self.tracks(["C"]), unplacedWaypoints: 0)
        async let fourth = choice.ask(fileName: "d.gpx", tracks: Self.tracks(["D"]), unplacedWaypoints: 0)
        await settleDelegateHop(until: "three to queue behind the first") { choice.waitingCount == 3 }

        var answered: [String] = []
        for remaining in (0...3).reversed() {
            await settleDelegateHop(until: "the next question") {
                choice.question.map { !answered.contains($0.fileName) } ?? false
            }
            answered.append(choice.question?.fileName ?? "")
            choice.cancel()
            #expect(choice.waitingCount == max(remaining - 1, 0))
        }
        #expect(answered.first == "a.gpx")
        #expect(Set(answered) == ["a.gpx", "b.gpx", "c.gpx", "d.gpx"])
        #expect(await [first, second, third, fourth].allSatisfy(\.isEmpty))

        choice.cancel()
        choice.confirm()
        async let next = choice.ask(fileName: "e.gpx", tracks: Self.tracks(["E"]), unplacedWaypoints: 0)
        await asked(choice)
        #expect(choice.waitingCount == 0)
        #expect(choice.question?.fileName == "e.gpx")
        choice.confirm()
        #expect(await next == [0])
    }

    /// The sheet's binding writes `nil` back as it closes after Import; that
    /// must not count as an answer to whatever is asked next.
    @Test("a cancel with nothing up answers nothing")
    func aStrayCancelAnswersNothing() async {
        let choice = GPXTrackChoice()
        choice.cancel()
        async let answer = choice.ask(fileName: "a.gpx", tracks: Self.tracks(["A", "B"]), unplacedWaypoints: 0)
        await asked(choice)
        choice.confirm()
        #expect(await answer == [0, 1])
    }
}
