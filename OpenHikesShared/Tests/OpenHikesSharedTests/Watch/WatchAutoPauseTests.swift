//
//  WatchAutoPauseTests.swift
//  OpenHikesSharedTests
//
//  What the watch's recorder does with Auto-Pause's answers: when it pauses,
//  which of the fixes it held go back to the track, and who may end the
//  pause. The rule itself is `AutoPauseWatchTests`'s; these streams are the
//  watch's, with no motion and no height.
//

import Foundation
@testable import OpenHikesShared
import Testing

// swiftlint:disable no_magic_numbers

@Suite("Watch auto-pause")
struct WatchAutoPauseTests {
    /// Each fix is held as the second it was taken at, so a departure says
    /// which of them it hands back.
    typealias Pause = WatchAutoPause<Int>

    @Test("five minutes in one place pauses from where the stop began")
    func stopPausesFromItsStart() {
        var pause = Pause()
        let observed = Fixture.walkUp + Fixture.standing(from: 60, to: 320)
        #expect(observed.compactMap { pause.observe($0) }.isEmpty)
        #expect(!pause.isPaused)

        #expect(pause.observe(Fixture.fix(north: 42, at: 340)) == Fixture.time(40))
        #expect(pause.isPaused)
        #expect(pause.decisionDate == nil, "nothing more to call while the pause stands")
    }

    @Test("walking away resumes from its first fix, and hands back that walk alone")
    func walkAwayIsTheNextSegment() throws {
        var pause = try Fixture.paused()
        for fix in Fixture.standing(from: 360, to: 600) {
            #expect(pause.hold(fix, as: Fixture.second(fix)) == nil)
        }

        let departure = try #require(Fixture.departure(&pause, holding: Fixture.walkAway))
        #expect(departure.since == Fixture.time(670))
        #expect(departure.walkedAway == [670, 680, 690, 700])
        #expect(!departure.beganBeforeThePause)
        #expect(!pause.isPaused)
    }

    @Test("a walk away delivered after the clock called the stop says it began first")
    func lateWalkAwaySaysSo() throws {
        var pause = Pause()
        let observed = Fixture.walkUp + Fixture.standing(from: 50, to: 90)
        #expect(observed.compactMap { pause.observe($0) }.isEmpty)
        #expect(pause.tick(at: Fixture.time(340)) == Fixture.time(40))

        let departure = try #require(Fixture.departure(&pause, holding: Fixture.walkAway(after: 30)))
        #expect(departure.since == Fixture.time(100))
        #expect(departure.beganBeforeThePause)
    }

    @Test("a silence after the hiker was seen standing is called by the clock")
    func silenceIsCalledByTheClock() {
        var pause = Pause()
        let observed = Fixture.walkUp + Fixture.standing(from: 50, to: 90)
        #expect(observed.compactMap { pause.observe($0) }.isEmpty)
        #expect(pause.decisionDate == Fixture.time(340))

        #expect(pause.tick(at: Fixture.time(339)) == nil)
        #expect(pause.tick(at: Fixture.time(340)) == Fixture.time(40))
        #expect(pause.isPaused)
        #expect(pause.tick(at: Fixture.time(400)) == nil, "one pause, not two")
    }

    @Test("with the switch off, no stop is called")
    func switchOffCallsNothing() {
        var pause = Pause()
        pause.isEnabled = false
        let observed = Fixture.walkUp + Fixture.standing(from: 60, to: 600)
        #expect(observed.compactMap { pause.observe($0) }.isEmpty)
        #expect(pause.decisionDate == nil)
        #expect(pause.tick(at: Fixture.time(700)) == nil)
        #expect(!pause.isPaused)
    }

    @Test("the switch going off makes the app's pause the hiker's")
    func switchOffHandsThePauseOver() throws {
        var pause = try Fixture.paused()
        pause.isEnabled = false
        #expect(!pause.isPaused)
        #expect(Fixture.departure(&pause, holding: Fixture.walkAway) == nil)
    }

    @Test("forgetting the app's pause leaves no walk away to end it")
    func resetEndsTheAppsPause() throws {
        var pause = try Fixture.paused()
        pause.reset()
        #expect(!pause.isPaused)
        #expect(Fixture.departure(&pause, holding: Fixture.walkAway) == nil)
    }

    @Test("a pause or resume by hand forgets the place, and a stop starts over")
    func resetForgetsThePlace() {
        var pause = Pause()
        let observed = Fixture.walkUp + Fixture.standing(from: 60, to: 240)
        #expect(observed.compactMap { pause.observe($0) }.isEmpty)
        pause.reset()

        let after = Fixture.standing(from: 260, to: 540)
        #expect(after.compactMap { pause.observe($0) }.isEmpty, "five minutes from the reset, not from 40 s")
        #expect(pause.observe(Fixture.fix(north: 42, at: 560)) == Fixture.time(260))
    }

    @Test("a relaunch takes the app's pause up again, at the first fix that can place it")
    func relaunchTakesThePauseUp() throws {
        var pause = Pause()
        pause.resumePause()
        #expect(pause.isPaused)
        #expect(pause.decisionDate == nil)
        // Forty metres off and too loose to stand for the place: taken for
        // it, it would make the hiker standing still a walk away.
        #expect(pause.hold(Fixture.fix(north: 0, at: 360, accuracy: 80), as: 360) == nil)
        for fix in Fixture.standing(from: 380, to: 600) {
            #expect(pause.hold(fix, as: Fixture.second(fix)) == nil)
        }

        let departure = try #require(Fixture.departure(&pause, holding: Fixture.walkAway))
        #expect(departure.since == Fixture.time(670))
        #expect(departure.walkedAway == [670, 680, 690, 700])
        #expect(!departure.beganBeforeThePause)
        #expect(!pause.isPaused)
    }

    @Test("with the switch off, a relaunch takes no pause up")
    func relaunchWithTheSwitchOff() {
        var pause = Pause()
        pause.isEnabled = false
        pause.resumePause()
        #expect(!pause.isPaused)
    }

    @Test("a stop and its walk away, taken as the recorder takes them, replay to the walk it showed")
    func recorderStepsReplay() throws {
        var recorder = RecorderSteps()
        for fix in Fixture.walkUp + Fixture.standing(from: 60, to: 600) + Fixture.walkAway {
            recorder.deliver(fix)
        }
        #expect(!recorder.pause.isPaused)
        let fixes = recorder.live.fixes
        let resumed = try #require(fixes.firstIndex { $0.resumesAfterPause })
        #expect(fixes[..<resumed].last?.timestamp == Fixture.time(40), "the stop is cut where it began")
        #expect(fixes[resumed...].map { Fixture.second($0.timestamp) } == [670, 680, 690, 700])

        let replayed = try #require(WatchRecoveredRecording.replaying(try recorder.journalData())).recording
        #expect(replayed.accumulator == recorder.live)
        #expect(!replayed.wasPaused)
    }

    @Test("a long stop holds no more fixes than a walk away needs")
    func longStopKeepsItsNewestFixes() throws {
        var pause = try Fixture.paused()
        for fix in Fixture.standing(from: 360, to: 3600) {
            _ = pause.hold(fix, as: Fixture.second(fix))
        }
        let departure = try #require(Fixture.departure(&pause, holding: Fixture.walkAway(after: 3600)))
        #expect(departure.since == Fixture.time(3670))
        #expect(departure.walkedAway == [3670, 3680, 3690, 3700])
    }

    private enum Fixture {
        static let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        static let metersPerDegree = WatchGeodesy.earthRadiusMeters * .pi / 180

        static func time(_ seconds: TimeInterval) -> Date {
            start.addingTimeInterval(seconds)
        }

        static func second(_ fix: AutoPauseWatch.Fix) -> Int {
            second(fix.timestamp)
        }

        static func second(_ date: Date) -> Int {
            Int(date.timeIntervalSince(start).rounded())
        }

        /// A watch fix `north` metres up the path, `seconds` into the walk:
        /// a position and a speed, and nothing else.
        static func fix(
            north: Double,
            at seconds: TimeInterval,
            speed: Double? = nil,
            accuracy: Double = 8
        ) -> AutoPauseWatch.Fix {
            AutoPauseWatch.Fix(
                latitude: 47.63 + north / metersPerDegree,
                longitude: 12.86,
                timestamp: time(seconds),
                horizontalAccuracy: accuracy,
                speed: speed
            )
        }

        /// Up the path at a metre a second, ten metres a fix, to 40 m at 40 s.
        static let walkUp = (0...4).map { step in
            fix(north: Double(step) * 10, at: Double(step) * 10, speed: 1)
        }

        /// Standing at about 42 m, a fix every twenty seconds, wandering a
        /// metre or two either way.
        static func standing(from first: TimeInterval, to last: TimeInterval) -> [AutoPauseWatch.Fix] {
            stride(from: first, through: last, by: 20).map { seconds in
                fix(north: 42 + (seconds.truncatingRemainder(dividingBy: 40) == 0 ? 1 : -1), at: seconds)
            }
        }

        /// On up the path, more than a minute after the last fix at the
        /// stop, so nothing taken there is part of the walk away.
        static func walkAway(after last: TimeInterval) -> [AutoPauseWatch.Fix] {
            (0...3).map { step in
                fix(north: 50 + Double(step) * 10, at: last + 70 + Double(step) * 10, speed: 1)
            }
        }

        static let walkAway = walkAway(after: 600)

        /// Holds each fix in turn until one ends the pause, and gives back
        /// the departure it made.
        static func departure(
            _ pause: inout Pause,
            holding fixes: [AutoPauseWatch.Fix]
        ) -> Pause.Departure? {
            for fix in fixes {
                if let departure = pause.hold(fix, as: second(fix)) { return departure }
            }
            return nil
        }

        /// Paused at 340 s, from 40 s.
        static func paused() throws -> Pause {
            var pause = Pause()
            let called = (walkUp + standing(from: 60, to: 340)).compactMap { pause.observe($0) }
            try #require(called == [time(40)])
            return pause
        }
    }

    /// What `WatchRecorder` does with each fix, step for step, over the
    /// shared parts alone: `received(_:)`, `beginAutoPause(since:)` and
    /// `receivedWhileAutoPaused(_:)`. The watch has no test bundle, so this
    /// is where the order of those steps is held to the journal.
    private struct RecorderSteps {
        var pause = WatchAutoPause<AutoPauseWatch.Fix>()
        var window = RecordingFixWindow(opensAt: Fixture.start)
        var live = WatchWalkAccumulator()
        var journal: [WatchRecordingJournalEntry] = [
            .began(WatchRecordingJournalHeader(sessionID: UUID(), startedAt: Fixture.start)),
        ]

        mutating func deliver(_ fix: AutoPauseWatch.Fix) {
            guard pause.isPaused else {
                received(fix)
                return
            }
            guard let departure = pause.hold(fix, as: fix) else { return }
            window.reopen(at: departure.since)
            journal.append(.resumed(departure.since))
            for walked in departure.walkedAway {
                received(walked)
            }
        }

        private mutating func received(_ fix: AutoPauseWatch.Fix) {
            guard window.admits(fix.timestamp) else { return }
            if let stoppedAt = pause.observe(fix) {
                live.pause(since: stoppedAt)
                journal.append(.autoPaused(stoppedAt))
                return
            }
            let kept = live.accept(
                latitude: fix.latitude,
                longitude: fix.longitude,
                timestamp: fix.timestamp,
                horizontalAccuracy: fix.horizontalAccuracy,
                elevationMeters: fix.elevation
            )
            if kept, let last = live.lastFix { journal.append(.fix(last)) }
        }

        func journalData() throws -> Data {
            try journal.reduce(into: Data()) { $0.append(try $1.line()) }
        }
    }
}

// swiftlint:enable no_magic_numbers
