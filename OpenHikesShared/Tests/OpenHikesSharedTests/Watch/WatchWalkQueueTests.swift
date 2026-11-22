//
//  WatchWalkQueueTests.swift
//  OpenHikesSharedTests
//

import Foundation
@testable import OpenHikesShared
import Testing

@Suite("Watch walk queue")
struct WatchWalkQueueTests {
    @Test("Walks come back oldest first, whatever order they were written in")
    func pendingIsOldestFirst() async throws {
        try await withQueue { queue in
            let late = Fixture.walk(endingAfter: 300)
            let early = Fixture.walk(endingAfter: 100)
            let middle = Fixture.walk(endingAfter: 200)
            for walk in [late, early, middle] {
                #expect(await queue.enqueue(walk) != nil)
            }

            let pending = await queue.pending()
            #expect(pending.sessionIDs == [early, middle, late].map(\.sessionID))
            #expect(await queue.walk(middle.sessionID) == middle)
        }
    }

    @Test("A relaunch counts and orders the queue without decoding a walk")
    func relaunchIndexesFromNamesAlone() async throws {
        try await withQueue { queue in
            let early = Fixture.walk(endingAfter: 100)
            let late = Fixture.walk(endingAfter: 200)
            _ = await queue.enqueue(late)
            _ = await queue.enqueue(early)

            // Every byte that is not a name made unreadable. A queue that
            // decoded to count would count nothing.
            for name in try fileNames(in: queue.directory) {
                try Data("not a walk".utf8).write(to: queue.directory.appending(path: name))
            }

            let relaunched = WatchWalkQueue(directory: queue.directory)
            #expect(await relaunched.pending().sessionIDs == [early.sessionID, late.sessionID])
        }
    }

    @Test("A receipt takes exactly its walk off, file and all")
    func removeDeletesOnlyThatWalk() async throws {
        try await withQueue { queue in
            let kept = Fixture.walk(endingAfter: 100)
            let confirmed = Fixture.walk(endingAfter: 200)
            _ = await queue.enqueue(kept)
            _ = await queue.enqueue(confirmed)

            let after = await queue.remove(confirmed.sessionID)
            #expect(after.sessionIDs == [kept.sessionID])
            #expect(await queue.walk(confirmed.sessionID) == nil)
            let names = try fileNames(in: queue.directory)
            #expect(names.count == 1)
            #expect(await WatchWalkQueue(directory: queue.directory).pending().sessionIDs == [kept.sessionID])
        }
    }

    @Test("A walk is taken while it reads back, and after its receipt, for this process only")
    func takenOutlivesTheReceipt() async throws {
        try await withQueue { queue in
            let walk = Fixture.walk(endingAfter: 100)
            let recording = Fixture.recording(of: walk, fixes: 2)
            let neverQueued = Fixture.recording(of: Fixture.walk(endingAfter: 200), fixes: 2)
            #expect(await !queue.hasTaken(recording))

            _ = await queue.enqueue(walk)
            #expect(await queue.hasTaken(recording))
            _ = await queue.remove(walk.sessionID)
            #expect(await queue.hasTaken(recording))
            // A receipt says the phone has the walk whether or not this
            // queue still held it.
            _ = await queue.remove(neverQueued.sessionID)
            #expect(await queue.hasTaken(neverQueued))

            #expect(await !WatchWalkQueue(directory: queue.directory).hasTaken(recording))
        }
    }

    @Test("A queued walk is taken only when it holds every fix the journal does")
    func takenOnlyWhenItCoversTheJournal() async throws {
        try await withQueue { queue in
            var walk = Fixture.walk(endingAfter: 100)
            _ = await queue.enqueue(walk)
            #expect(await queue.hasTaken(Fixture.recording(of: walk, fixes: 1)))

            // A journal carried on past the copy, as Continue leaves one.
            walk.fixes.append(
                WatchRecordedFix(
                    latitude: 47.5503,
                    longitude: 12.90,
                    timestamp: walk.endedAt.addingTimeInterval(60),
                    horizontalAccuracy: 5
                )
            )
            let carriedOn = Fixture.recording(of: walk, fixes: 3)
            #expect(carriedOn.accumulator.fixes.count == 3)
            #expect(await !queue.hasTaken(carriedOn))
        }
    }

    @Test("Every change moves the revision on, and a read does not")
    func revisionOrdersAnswers() async throws {
        try await withQueue { queue in
            let walk = Fixture.walk(endingAfter: 100)
            let empty = await queue.pending()
            let queued = try #require(await queue.enqueue(walk))
            let read = await queue.pending()
            let removed = await queue.remove(walk.sessionID)
            let removedAgain = await queue.remove(walk.sessionID)

            #expect(queued.isNewer(than: empty))
            #expect(!empty.isNewer(than: queued))
            #expect(read.revision == queued.revision)
            #expect(removed.isNewer(than: read) && !read.isNewer(than: removed))
            // A receipt for a walk already gone changes nothing.
            #expect(removedAgain.revision == removed.revision)
        }
    }

    @Test("The same session written again leaves one file")
    func rewriteReplacesTheFile() async throws {
        try await withQueue { queue in
            var walk = Fixture.walk(endingAfter: 100)
            _ = await queue.enqueue(walk)
            walk.endedAt = walk.endedAt.addingTimeInterval(60)
            let pending = try #require(await queue.enqueue(walk))

            #expect(pending.sessionIDs == [walk.sessionID])
            let names = try fileNames(in: queue.directory)
            #expect(names.count == 1)
            #expect(await queue.walk(walk.sessionID) == walk)
        }
    }

    /// Written beside its old file and the old one removed after, a process
    /// killed between the two left both, and the next launch's index kept
    /// whichever it listed first: a continued walk could lose to the copy it
    /// carried on from (#1572).
    @Test("The same session written again goes over its own file, and keeps its place")
    func rewriteGoesOverItsOwnFile() async throws {
        try await withQueue { queue in
            var walk = Fixture.walk(endingAfter: 100)
            let later = Fixture.walk(endingAfter: 150)
            _ = await queue.enqueue(walk)
            _ = await queue.enqueue(later)
            let names = try fileNames(in: queue.directory)

            walk.endedAt = walk.endedAt.addingTimeInterval(600)
            walk.fixes.append(
                WatchRecordedFix(latitude: 47.5503, longitude: 12.90, timestamp: walk.endedAt, horizontalAccuracy: 5)
            )
            #expect(await queue.enqueue(walk)?.sessionIDs == [walk.sessionID, later.sessionID])

            #expect(try Set(fileNames(in: queue.directory)) == Set(names))
            let relaunched = WatchWalkQueue(directory: queue.directory)
            #expect(await relaunched.walk(walk.sessionID) == walk)
            #expect(await relaunched.pending().sessionIDs == [walk.sessionID, later.sessionID])
        }
    }

    @Test("A file named before the index is read once and renamed")
    func olderFileIsAdopted() async throws {
        try await withQueue { queue in
            let older = Fixture.walk(endingAfter: 300)
            let newer = Fixture.walk(endingAfter: 100)
            try FileManager.default.createDirectory(at: queue.directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(older)
                .write(to: queue.directory.appending(path: "\(older.sessionID.uuidString).json"))
            _ = await queue.enqueue(newer)

            let relaunched = WatchWalkQueue(directory: queue.directory)
            #expect(await relaunched.pending().sessionIDs == [newer.sessionID, older.sessionID])
            let names = try fileNames(in: queue.directory)
            #expect(!names.contains("\(older.sessionID.uuidString).json"))
            #expect(await relaunched.walk(older.sessionID) == older)
        }
    }

    @Test("A walk that cannot decode stops counting, and its file stays")
    func undecodableWalkLeavesTheCount() async throws {
        try await withQueue { queue in
            let broken = Fixture.walk(endingAfter: 100)
            let fine = Fixture.walk(endingAfter: 200)
            _ = await queue.enqueue(broken)
            _ = await queue.enqueue(fine)
            let written = try fileNames(in: queue.directory)
            let brokenName = try #require(written.first { $0.contains(broken.sessionID.uuidString) })
            try Data("{".utf8).write(to: queue.directory.appending(path: brokenName))

            let relaunched = WatchWalkQueue(directory: queue.directory)
            #expect(await relaunched.pending().count == 2)
            #expect(await relaunched.walk(broken.sessionID) == nil)
            #expect(await relaunched.pending().sessionIDs == [fine.sessionID])
            let names = try fileNames(in: queue.directory)
            #expect(names.contains(brokenName))
        }
    }

    @Test(
        "A walk in a format this build does not read is refused, and its file stays",
        arguments: [WatchRecordedWalk.currentSchemaVersion - 1, 999]
    )
    func unsupportedVersionIsRefusedAndKept(version: Int) async throws {
        try await withQueue { queue in
            let other = Fixture.walk(endingAfter: 100)
            let fine = Fixture.walk(endingAfter: 200)
            _ = await queue.enqueue(other)
            _ = await queue.enqueue(fine)
            let written = try fileNames(in: queue.directory)
            let otherName = try #require(written.first { $0.contains(other.sessionID.uuidString) })
            let otherURL = queue.directory.appending(path: otherName)
            // Every field intact and only the version changed: the walk a
            // build on the other side of a format change would have queued.
            let original = try Data(contentsOf: otherURL)
            var object = try #require(try JSONSerialization.jsonObject(with: original) as? [String: Any])
            object["schemaVersion"] = version
            let rewritten = try JSONSerialization.data(withJSONObject: object)
            try rewritten.write(to: otherURL)

            let relaunched = WatchWalkQueue(directory: queue.directory)
            #expect(await relaunched.walk(other.sessionID) == nil)
            #expect(await relaunched.walk(fine.sessionID) == fine)
            #expect(await relaunched.pending().sessionIDs == [fine.sessionID])
            // Possibly the only copy of a recording, so it is never deleted.
            #expect(try Data(contentsOf: otherURL) == rewritten)
        }
    }

    @Test("A fresh copy of a walk that would not decode replaces its file", arguments: [false, true])
    func undecodableWalkIsReplaced(namedBeforeTheIndex: Bool) async throws {
        try await withQueue { queue in
            var walk = Fixture.walk(endingAfter: 100)
            if namedBeforeTheIndex {
                try FileManager.default.createDirectory(at: queue.directory, withIntermediateDirectories: true)
                try Data("{".utf8).write(to: queue.directory.appending(path: "\(walk.sessionID.uuidString).json"))
            } else {
                _ = await queue.enqueue(walk)
                let name = try #require(try fileNames(in: queue.directory).first)
                try Data("{".utf8).write(to: queue.directory.appending(path: name))
            }

            let relaunched = WatchWalkQueue(directory: queue.directory)
            #expect(await relaunched.walk(walk.sessionID) == nil)
            #expect(await relaunched.pending().isEmpty)
            // Recovered from its journal, so it ends at a different moment,
            // and written over the file that would not decode.
            walk.endedAt = walk.endedAt.addingTimeInterval(-30)
            #expect(await relaunched.enqueue(walk)?.sessionIDs == [walk.sessionID])

            #expect(try fileNames(in: queue.directory).count == 1)
            #expect(await relaunched.walk(walk.sessionID) == walk)
            #expect(await WatchWalkQueue(directory: queue.directory).walk(walk.sessionID) == walk)
        }
    }

    @Test("A listing that fails is tried again rather than taken for an empty queue")
    func failedListingIsRetried() async throws {
        try await withQueue { queue in
            let walk = Fixture.walk(endingAfter: 100)
            _ = await queue.enqueue(walk)
            let moved = queue.directory.appendingPathExtension("away")
            try FileManager.default.moveItem(at: queue.directory, to: moved)
            defer { try? FileManager.default.removeItem(at: moved) }
            // A file where the directory should be: there, and not listable.
            try Data().write(to: queue.directory)

            let relaunched = WatchWalkQueue(directory: queue.directory)
            let failed = await relaunched.pending()
            #expect(failed.isEmpty)

            try FileManager.default.removeItem(at: queue.directory)
            try FileManager.default.moveItem(at: moved, to: queue.directory)
            let listed = await relaunched.pending()
            #expect(listed.sessionIDs == [walk.sessionID])
            #expect(listed.isNewer(than: failed) && !failed.isNewer(than: listed))
            #expect(await relaunched.walk(walk.sessionID) == walk)
        }
    }

    @Test("Nothing on disk is an empty queue, and stray files are not walks")
    func strayFilesAreIgnored() async throws {
        try await withQueue { queue in
            #expect(await queue.pending().isEmpty)

            try FileManager.default.createDirectory(at: queue.directory, withIntermediateDirectories: true)
            for name in ["notes.txt", "12_not-a-uuid.json", ".DS_Store", "x_\(UUID().uuidString).json"] {
                try Data().write(to: queue.directory.appending(path: name))
            }
            #expect(await WatchWalkQueue(directory: queue.directory).pending().isEmpty)
        }
    }

    @Test("A write that fails says so and changes nothing")
    func failedWriteIsReported() async throws {
        let blocker = FileManager.default.temporaryDirectory.appending(path: "walk-queue-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: blocker) }
        // A file where the directory should be.
        try Data().write(to: blocker)
        let queue = WatchWalkQueue(directory: blocker)

        #expect(await queue.enqueue(Fixture.walk(endingAfter: 100)) == nil)
        #expect(await queue.pending() == WatchQueuedWalks(sessionIDs: [], revision: 0))
    }

    private func withQueue(_ body: (WatchWalkQueue) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "walk-queue-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try await body(WatchWalkQueue(directory: directory))
    }

    private func fileNames(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))
    }

    private enum Fixture {
        static let start = Date(timeIntervalSince1970: 1_700_000_000)

        static func walk(endingAfter seconds: TimeInterval) -> WatchRecordedWalk {
            let fixes = (0..<2).map { step in
                WatchRecordedFix(
                    latitude: 47.55 + Double(step) * 0.0001,
                    longitude: 12.90,
                    timestamp: start.addingTimeInterval(Double(step) * seconds),
                    horizontalAccuracy: 5
                )
            }
            return WatchRecordedWalk(
                sessionID: UUID(),
                startedAt: start,
                // Whole milliseconds, which is what the file name keeps.
                endedAt: start.addingTimeInterval(seconds),
                distanceMeters: 11,
                activeSeconds: seconds,
                fixes: fixes
            )
        }

        /// The journal of `walk` as its first `count` fixes, or of a walk
        /// carried further when `count` is more than it holds.
        static func recording(of walk: WatchRecordedWalk, fixes count: Int) -> WatchRecoveredRecording {
            var recording = WatchRecoveredRecording(
                header: WatchRecordingJournalHeader(sessionID: walk.sessionID, startedAt: walk.startedAt),
                accumulator: WatchWalkAccumulator(),
                wasPaused: false,
                lastRecordedAt: walk.startedAt
            )
            recording.carryOn(through: walk.fixes.prefix(count))
            return recording
        }
    }
}
