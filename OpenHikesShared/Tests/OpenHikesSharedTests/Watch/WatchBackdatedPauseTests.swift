//
//  WatchBackdatedPauseTests.swift
//  OpenHikesSharedTests
//
//  A pause Auto-Pause makes on the watch, minutes after the stop it is
//  counted from: the accumulator takes the stop's fixes back, and the
//  journal line that says so replays to the same walk, and to whose pause
//  it is.
//

import Foundation
@testable import OpenHikesShared
import Testing

// swiftlint:disable no_magic_numbers

@Suite("Watch backdated pause")
struct WatchBackdatedPauseTests {
    @Test("the fixes kept after the stop began are taken back, with what they added")
    func cutTakesTheStopBack() {
        var live = Fixture.accumulator(steps: 0...6)
        live.pause(since: Fixture.time(step: 3))

        var paused = Fixture.accumulator(steps: 0...3)
        paused.pause()
        #expect(live == paused)
        #expect(live.fixes.count == 4)
        #expect(live.activeSeconds == 24)
    }

    @Test("the next fix after the cut opens a new segment")
    func nextFixOpensANewLeg() {
        var live = Fixture.accumulator(steps: 0...6)
        live.pause(since: Fixture.time(step: 3))
        let before = live.distanceMeters
        Fixture.accept(Fixture.fix(step: 8), into: &live)

        #expect(live.lastFix?.resumesAfterPause == true)
        #expect(live.distanceMeters == before)
    }

    @Test("an earlier pause by hand is where it was after the cut")
    func earlierPauseSurvivesTheCut() {
        var live = Fixture.accumulator(steps: 0...2)
        live.pause()
        for step in 3...7 { Fixture.accept(Fixture.fix(step: step), into: &live) }
        live.pause(since: Fixture.time(step: 5))

        #expect(live.fixes.map(\.resumesAfterPause) == [false, false, false, true, false, false])
        var expected = Fixture.accumulator(steps: 0...2)
        expected.pause()
        for step in 3...5 { Fixture.accept(Fixture.fix(step: step), into: &expected) }
        expected.pause()
        #expect(live == expected)
    }

    @Test("a stop that began at the last fix is a pause by hand")
    func cutAtTheEndTakesNothing() {
        var live = Fixture.accumulator(steps: 0...4)
        live.pause(since: Fixture.time(step: 4))
        var paused = Fixture.accumulator(steps: 0...4)
        paused.pause()
        #expect(live == paused)
    }

    @Test("a journal with the line replays to the walk the recording showed")
    func journalReplaysTheCut() throws {
        var live = Fixture.accumulator(steps: 0...6)
        var entries: [WatchRecordingJournalEntry] = [.began(Fixture.header)] + live.fixes.map { .fix($0) }
        live.pause(since: Fixture.time(step: 3))
        entries.append(.autoPaused(Fixture.time(step: 3)))

        let paused = try #require(WatchRecoveredRecording.replaying(try Fixture.data(entries))).recording
        #expect(paused.accumulator == live)
        #expect(paused.accumulator.fixes.last?.timestamp == Fixture.time(step: 3))
        #expect(paused.wasPaused)
        #expect(paused.wasAutoPaused, "a relaunch under the recovered session takes it up again")

        Fixture.accept(Fixture.fix(step: 9), into: &live)
        entries += [.resumed(Fixture.time(step: 9)), .fix(try #require(live.lastFix))]
        let resumed = try #require(WatchRecoveredRecording.replaying(try Fixture.data(entries))).recording
        #expect(resumed.accumulator == live)
        #expect(!resumed.wasPaused)
        #expect(!resumed.wasAutoPaused)
    }

    @Test("a pause the hiker took over from the app is theirs after a relaunch")
    func takenOverPauseIsTheHikers() throws {
        var live = Fixture.accumulator(steps: 0...6)
        let entries: [WatchRecordingJournalEntry] = [.began(Fixture.header)]
            + live.fixes.map { .fix($0) }
            + [.autoPaused(Fixture.time(step: 3)), .paused(Fixture.time(step: 9))]
        live.pause(since: Fixture.time(step: 3))

        let recovered = try #require(WatchRecoveredRecording.replaying(try Fixture.data(entries))).recording
        #expect(recovered.accumulator == live)
        #expect(recovered.wasPaused)
        #expect(!recovered.wasAutoPaused)
    }

    private enum Fixture {
        static let start = Date(timeIntervalSince1970: 1_700_000_000)
        static let header = WatchRecordingJournalHeader(sessionID: UUID(), startedAt: start)

        static func time(step: Int) -> Date {
            start.addingTimeInterval(Double(step) * 8)
        }

        /// About 11 m due north a step, which every gate keeps.
        static func fix(step: Int) -> WatchRecordedFix {
            WatchRecordedFix(
                latitude: 47.55 + Double(step) * 0.0001,
                longitude: 12.90,
                timestamp: time(step: step),
                horizontalAccuracy: 5,
                elevationMeters: 600 + Double(step) * 2
            )
        }

        static func accept(_ fix: WatchRecordedFix, into accumulator: inout WatchWalkAccumulator) {
            accumulator.accept(
                latitude: fix.latitude,
                longitude: fix.longitude,
                timestamp: fix.timestamp,
                horizontalAccuracy: fix.horizontalAccuracy,
                elevationMeters: fix.elevationMeters
            )
        }

        static func accumulator(steps: ClosedRange<Int>) -> WatchWalkAccumulator {
            var accumulator = WatchWalkAccumulator()
            for step in steps { accept(fix(step: step), into: &accumulator) }
            return accumulator
        }

        static func data(_ entries: [WatchRecordingJournalEntry]) throws -> Data {
            try entries.reduce(into: Data()) { $0.append(try $1.line()) }
        }
    }
}

// swiftlint:enable no_magic_numbers
