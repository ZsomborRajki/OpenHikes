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

    /// Two sheets cannot be up at once, and the first question would otherwise
    /// wait for an answer nobody can give.
    @Test("a second question answers the first with none")
    func aSecondQuestionEndsTheFirst() async {
        let choice = GPXTrackChoice()
        async let first = choice.ask(fileName: "a.gpx", tracks: Self.tracks(["A", "B"]), unplacedWaypoints: 0)
        await asked(choice)
        async let second = choice.ask(fileName: "b.gpx", tracks: Self.tracks(["C", "D"]), unplacedWaypoints: 0)

        #expect(await first.isEmpty)
        await settleDelegateHop(until: "the second question") { choice.question?.fileName == "b.gpx" }
        choice.confirm()
        #expect(await second == [0, 1])
    }
}
