//
//  WatchRecordingRecoveryTests.swift
//  OpenHikesSharedTests
//

import Foundation
@testable import OpenHikesShared
import Testing

@Suite("Watch recording recovery at launch")
struct WatchRecordingRecoveryTests {
    @Test("No journal is nothing to recover")
    func missingJournalIsNothing() async throws {
        try await withStore { journal, queue in
            #expect(await WatchRecordingRecovery.checking(journal, against: queue) == .nothing)

            try FileManager.default.createDirectory(
                at: journal.url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try WatchRecordingJournalEntry.fix(Fixture.fix(step: 0)).line().write(to: journal.url)
            #expect(await WatchRecordingRecovery.checking(journal, against: queue) == .nothing)
        }
    }

    @Test("A journal whose walk is not on the queue is offered")
    func unqueuedJournalIsOffered() async throws {
        try await withStore { journal, queue in
            try Fixture.write(steps: 3, to: journal)
            #expect(await queue.enqueue(Fixture.otherWalk) != nil)

            let recovery = await WatchRecordingRecovery.checking(journal, against: queue)
            guard case .offer(let recovered) = recovery else {
                Issue.record("Expected an offer, got \(recovery)")
                return
            }
            #expect(recovered.header == Fixture.header)
            #expect(recovered.accumulator.fixes.count == 4)
        }
    }

    @Test("A walk already on the queue is not offered a second time")
    func queuedWalkIsNotOfferedAgain() async throws {
        try await withStore { journal, queue in
            try Fixture.write(steps: 3, to: journal)
            let recovered = try #require(journal.recover())
            #expect(await queue.enqueue(try #require(recovered.finishedWalk())) != nil)

            let relaunched = WatchWalkQueue(directory: queue.directory)
            #expect(await WatchRecordingRecovery.checking(journal, against: relaunched) == .alreadyQueued)
        }
    }

    /// The launch drain can send the queued walk while the journal is still
    /// replaying, and the phone's receipt can take it off the queue before
    /// the check asks. Offered then, Continue would carry on a walk the phone
    /// already has under the same session, and the phone would drop what
    /// came after as a second arrival.
    @Test("A walk the phone confirmed before the check asked is not offered again")
    func walkConfirmedDuringTheCheckIsNotOffered() async throws {
        try await withStore { journal, queue in
            try Fixture.write(steps: 3, to: journal)
            let recovered = try #require(journal.recover())
            let walk = try #require(recovered.finishedWalk())
            #expect(await queue.enqueue(walk) != nil)

            let relaunched = WatchWalkQueue(directory: queue.directory)
            #expect(await relaunched.remove(walk.sessionID).isEmpty)
            #expect(await WatchRecordingRecovery.checking(journal, against: relaunched) == .alreadyQueued)
        }
    }

    /// Continue carries a walk on in its journal, under the session whose
    /// shorter copy the last Stop queued. Killed before the next Stop, the
    /// launch after finds the copy readable: let go of beside it, the journal
    /// took everything after Continue with it (#1572).
    @Test("A journal carried on past its queued walk is offered, not let go")
    func journalAheadOfItsQueuedWalkIsOffered() async throws {
        try await withStore { journal, queue in
            try Fixture.write(steps: 6, to: journal)
            #expect(await queue.enqueue(try #require(Fixture.walk(steps: 3))) != nil)

            let relaunched = WatchWalkQueue(directory: queue.directory)
            let recovery = await WatchRecordingRecovery.checking(journal, against: relaunched)
            guard case .offer(let recovered) = recovery else {
                Issue.record("Expected an offer, got \(recovery)")
                return
            }
            #expect(recovered.accumulator.fixes.count == 7)
        }
    }

    /// Stop writes the walk from the accumulator and lets the journal go
    /// without writing what it still held, so a queued walk can be a batch
    /// of fixes ahead of the journal beside it.
    @Test("A queued walk ahead of its journal is the walk, not a second offer")
    func queuedWalkAheadOfItsJournalIsTaken() async throws {
        try await withStore { journal, queue in
            try Fixture.write(steps: 3, to: journal)
            #expect(await queue.enqueue(try #require(Fixture.walk(steps: 6))) != nil)

            let relaunched = WatchWalkQueue(directory: queue.directory)
            #expect(await WatchRecordingRecovery.checking(journal, against: relaunched) == .alreadyQueued)
        }
    }

    /// What Save keeps and Continue carries on from, when the last Stop's
    /// copy reads at the hiker's answer (#1572).
    @Test("A queued walk ahead of its journal hands back the fixes between, and carrying on through them is the walk")
    func queuedWalkAheadHandsBackItsTail() async throws {
        try await withStore { journal, _ in
            try Fixture.write(steps: 3, to: journal)
            var recovered = try #require(journal.recover())
            let queued = try #require(Fixture.walk(steps: 6, pausingBefore: 5))

            let tail = try #require(recovered.tail(in: queued))
            #expect(tail.map(\.timestamp) == (4...6).map { Fixture.fix(step: $0).timestamp })
            recovered.carryOn(through: tail)
            #expect(recovered.accumulator.fixes == queued.fixes)
            #expect(recovered.accumulator.fixes[5].resumesAfterPause)
            #expect(recovered.lastRecordedAt == Fixture.fix(step: 6).timestamp)
            #expect(recovered.finishedWalk()?.distanceMeters == queued.distanceMeters)
            #expect(recovered.tail(in: queued)?.isEmpty == true)
        }
    }

    @Test("A walk of another session, or one its journal has run past, hands back no tail")
    func walkBehindItsJournalHandsBackNothing() async throws {
        try await withStore { journal, _ in
            try Fixture.write(steps: 6, to: journal)
            let recovered = try #require(journal.recover())

            #expect(recovered.tail(in: try #require(Fixture.walk(steps: 3))) == nil)
            #expect(recovered.tail(in: Fixture.otherWalk) == nil)
            // As many fixes, and the last not the journal's.
            var other = try #require(Fixture.walk(steps: 6))
            other.fixes[6].timestamp.addTimeInterval(1)
            #expect(recovered.tail(in: other) == nil)
        }
    }

    @Test(
        "A file named for the walk that is not one leaves the journal offered",
        arguments: [false, true]
    )
    func undecodableQueuedWalkIsOffered(namedBeforeTheIndex: Bool) async throws {
        try await withStore { journal, queue in
            try Fixture.write(steps: 3, to: journal)
            let recovered = try #require(journal.recover())
            let walk = try #require(recovered.finishedWalk())
            let fileName = if namedBeforeTheIndex {
                "\(walk.sessionID.uuidString).json"
            } else {
                "\(Int64(walk.endedAt.timeIntervalSince1970 * 1000))_\(walk.sessionID.uuidString).json"
            }
            try FileManager.default.createDirectory(at: queue.directory, withIntermediateDirectories: true)
            try Data("{".utf8).write(to: queue.directory.appending(path: fileName))

            let recovery = await WatchRecordingRecovery.checking(journal, against: queue)
            guard case .offer(let recovered) = recovery else {
                Issue.record("Expected an offer, got \(recovery)")
                return
            }
            #expect(recovered.sessionID == walk.sessionID)
        }
    }

    @Test("A torn tail is cut off at launch, so the walk carries on after a whole line")
    func tornTailIsCutAtLaunch() async throws {
        try await withStore { journal, queue in
            try Fixture.write(steps: 3, to: journal)
            let whole = try Data(contentsOf: journal.url)
            let torn = try WatchRecordingJournalEntry.fix(Fixture.fix(step: 4)).line()
            let handle = try FileHandle(forWritingTo: journal.url)
            try handle.seekToEnd()
            try handle.write(contentsOf: torn.prefix(torn.count / 2))
            try handle.close()

            let recovery = await WatchRecordingRecovery.checking(journal, against: queue)
            guard case .offer(let recovered) = recovery else {
                Issue.record("Expected an offer, got \(recovery)")
                return
            }
            #expect(recovered.accumulator.fixes.count == 4)
            #expect(try Data(contentsOf: journal.url) == whole)
        }
    }

    private func withStore(
        _ body: (WatchRecordingJournalFile, WatchWalkQueue) async throws -> Void
    ) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "watch-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try await body(
            WatchRecordingJournalFile(url: directory.appending(path: "recording.jsonl")),
            WatchWalkQueue(directory: directory.appending(path: "walks"))
        )
    }

    private enum Fixture {
        static let start = Date(timeIntervalSince1970: 1_700_000_000)
        static let header = WatchRecordingJournalHeader(
            sessionID: UUID(uuidString: "77777777-7777-7777-7777-777777777777") ?? UUID(),
            startedAt: start.addingTimeInterval(-5),
            title: "Thumsee Loop"
        )

        /// About 11 m due north a step, which every gate keeps.
        static func fix(step: Int) -> WatchRecordedFix {
            WatchRecordedFix(
                latitude: 47.55 + Double(step) * 0.0001,
                longitude: 12.90,
                timestamp: start.addingTimeInterval(Double(step) * 8),
                horizontalAccuracy: 5
            )
        }

        /// A walk of another session, already waiting for the phone.
        static let otherWalk = WatchRecordedWalk(
            sessionID: UUID(),
            startedAt: start,
            endedAt: start.addingTimeInterval(8),
            distanceMeters: 11,
            activeSeconds: 8,
            fixes: [fix(step: 0), fix(step: 1)]
        )

        /// A journal as a recording of `0...steps` would have left it.
        static func write(steps: Int, to journal: WatchRecordingJournalFile) throws {
            try journal.begin(header)
            try journal.append((0...steps).map { .fix(fix(step: $0)) })
        }

        /// The walk Stop would have queued for a recording of `0...steps`,
        /// paused before `pausedStep` when there is one.
        static func walk(steps: Int, pausingBefore pausedStep: Int? = nil) -> WatchRecordedWalk? {
            var accumulator = WatchWalkAccumulator()
            for (step, fix) in (0...steps).map({ ($0, fix(step: $0)) }) {
                if step == pausedStep { accumulator.pause() }
                accumulator.accept(
                    latitude: fix.latitude,
                    longitude: fix.longitude,
                    timestamp: fix.timestamp,
                    horizontalAccuracy: fix.horizontalAccuracy
                )
            }
            return accumulator.recordedWalk(
                sessionID: header.sessionID,
                startedAt: header.startedAt,
                endedAt: fix(step: steps).timestamp.addingTimeInterval(2),
                trailHikeID: nil,
                title: header.title
            )
        }
    }
}
