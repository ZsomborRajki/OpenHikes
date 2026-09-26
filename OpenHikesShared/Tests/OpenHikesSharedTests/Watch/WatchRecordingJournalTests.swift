//
//  WatchRecordingJournalTests.swift
//  OpenHikesSharedTests
//

import Foundation
@testable import OpenHikesShared
import Testing

@Suite("Watch recording journal replay")
struct WatchRecordingJournalTests {
    @Test("A replayed journal is the recording that wrote it")
    func replayMatchesTheLiveAccumulator() throws {
        let (live, entries) = Fixture.recording(steps: 6, pauseAfter: 3)
        let (recovered, validByteCount) = try #require(
            WatchRecoveredRecording.replaying(try Fixture.data(entries))
        )
        #expect(recovered.accumulator == live)
        #expect(recovered.header == Fixture.header)
        #expect(validByteCount == (try Fixture.data(entries)).count)
    }

    @Test("A pause keeps the leg it ended out of the distance")
    func replayedPauseBreaksTheLeg() throws {
        let (live, entries) = Fixture.recording(steps: 6, pauseAfter: 3)
        let recovered = try #require(WatchRecoveredRecording.replaying(try Fixture.data(entries))).recording
        #expect(recovered.accumulator.fixes.filter(\.resumesAfterPause).count == 1)
        #expect(recovered.accumulator.distanceMeters == live.distanceMeters)
        #expect(!recovered.wasPaused)
    }

    @Test("The last thing the hiker did decides whether it was paused")
    func trailingPauseIsRemembered() throws {
        var (_, entries) = Fixture.recording(steps: 3)
        entries.append(.paused(Fixture.time(step: 4)))
        let recovered = try #require(WatchRecoveredRecording.replaying(try Fixture.data(entries))).recording
        #expect(recovered.wasPaused)
        #expect(recovered.lastRecordedAt == Fixture.time(step: 4))
    }

    @Test("Half a line at the end is dropped, and everything before it kept")
    func tornTailIsCutOff() throws {
        let (_, entries) = Fixture.recording(steps: 4)
        let whole = try Fixture.data(entries)
        let torn = try WatchRecordingJournalEntry.fix(Fixture.fix(step: 5)).line()
        let data = whole + torn.prefix(torn.count / 2)

        let (recovered, validByteCount) = try #require(WatchRecoveredRecording.replaying(data))
        #expect(recovered.accumulator.fixes.count == 5)
        #expect(validByteCount == whole.count)
    }

    @Test("Nothing after an undecodable line is trusted")
    func replayStopsAtTheFirstBadLine() throws {
        let (_, entries) = Fixture.recording(steps: 4)
        let head = try Fixture.data(Array(entries.prefix(3)))
        let tail = try Fixture.data(Array(entries.dropFirst(3)))
        let data = head + Data("not json\n".utf8) + tail

        let (recovered, validByteCount) = try #require(WatchRecoveredRecording.replaying(data))
        #expect(recovered.accumulator.fixes.count == 2)
        #expect(validByteCount == head.count)
    }

    @Test("A journal without its header is not a recording")
    func headerlessJournalIsRefused() throws {
        let (_, entries) = Fixture.recording(steps: 3)
        #expect(WatchRecoveredRecording.replaying(try Fixture.data(Array(entries.dropFirst()))) == nil)
        #expect(WatchRecoveredRecording.replaying(Data()) == nil)
    }

    @Test("A second header ends the replay rather than restarting it")
    func secondHeaderEndsTheReplay() throws {
        let (_, entries) = Fixture.recording(steps: 3)
        let data = try Fixture.data(entries + [.began(Fixture.header)] + entries.dropFirst())
        let recovered = try #require(WatchRecoveredRecording.replaying(data)).recording
        #expect(recovered.accumulator.fixes.count == 4)
    }

    @Test("A recovered walk ends at its last durable line, not at the relaunch")
    func finishedWalkEndsWhereTheJournalDoes() throws {
        let (live, entries) = Fixture.recording(steps: 5)
        let recovered = try #require(WatchRecoveredRecording.replaying(try Fixture.data(entries))).recording
        let walk = try #require(recovered.finishedWalk())
        #expect(walk.sessionID == Fixture.header.sessionID)
        #expect(walk.startedAt == Fixture.header.startedAt)
        #expect(walk.endedAt == Fixture.time(step: 5))
        #expect(walk.trailHikeID == Fixture.header.trailHikeID)
        #expect(walk.title == Fixture.header.title)
        #expect(walk.fixes == live.fixes)
    }

    @Test("A journal with one fix in it is not a walk")
    func singleFixIsNotAWalk() throws {
        let (_, entries) = Fixture.recording(steps: 0)
        let recovered = try #require(WatchRecoveredRecording.replaying(try Fixture.data(entries))).recording
        #expect(recovered.finishedWalk() == nil)
    }

    @Test("A walk already on the queue is not offered a second time")
    func queuedWalkIsNotOfferedAgain() throws {
        let (_, entries) = Fixture.recording(steps: 3)
        let recovered = try #require(WatchRecoveredRecording.replaying(try Fixture.data(entries))).recording
        #expect(WatchRecordingRecovery.resolve(nil, queued: []) == .nothing)
        #expect(WatchRecordingRecovery.resolve(recovered, queued: [recovered.sessionID]) == .alreadyQueued)
        #expect(WatchRecordingRecovery.resolve(recovered, queued: [UUID()]) == .offer(recovered))
    }

    private enum Fixture {
        static let start = Date(timeIntervalSince1970: 1_700_000_000)
        static let header = WatchRecordingJournalHeader(
            sessionID: UUID(uuidString: "44444444-4444-4444-4444-444444444444") ?? UUID(),
            startedAt: start.addingTimeInterval(-5),
            trailHikeID: UUID(uuidString: "55555555-5555-5555-5555-555555555555"),
            title: "Thumsee Loop"
        )

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

        /// A live accumulator and the journal it would have written, with a
        /// pause and a resume after `pauseAfter` when there is one.
        static func recording(
            steps: Int,
            pauseAfter: Int? = nil
        ) -> (WatchWalkAccumulator, [WatchRecordingJournalEntry]) {
            var live = WatchWalkAccumulator()
            var entries: [WatchRecordingJournalEntry] = [.began(header)]
            for step in 0...steps {
                let fix = fix(step: step)
                live.accept(
                    latitude: fix.latitude,
                    longitude: fix.longitude,
                    timestamp: fix.timestamp,
                    horizontalAccuracy: fix.horizontalAccuracy,
                    elevationMeters: fix.elevationMeters
                )
                if let kept = live.lastFix { entries.append(.fix(kept)) }
                if step == pauseAfter {
                    live.pause()
                    entries.append(.paused(fix.timestamp.addingTimeInterval(1)))
                    entries.append(.resumed(fix.timestamp.addingTimeInterval(2)))
                }
            }
            return (live, entries)
        }

        static func data(_ entries: [WatchRecordingJournalEntry]) throws -> Data {
            try entries.reduce(into: Data()) { $0.append(try $1.line()) }
        }
    }
}
