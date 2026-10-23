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
            #expect(relaunched.listedSessionIDs() == [early.sessionID, late.sessionID])
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

    @Test("A file named before the index is read once and renamed")
    func olderFileIsAdopted() async throws {
        try await withQueue { queue in
            let older = Fixture.walk(endingAfter: 300)
            let newer = Fixture.walk(endingAfter: 100)
            try FileManager.default.createDirectory(at: queue.directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(older)
                .write(to: queue.directory.appending(path: "\(older.sessionID.uuidString).json"))
            _ = await queue.enqueue(newer)

            // Seen by a launch-time listing before anything has renamed it.
            #expect(queue.listedSessionIDs() == [older.sessionID, newer.sessionID])

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

    @Test("Nothing on disk is an empty queue, and stray files are not walks")
    func strayFilesAreIgnored() async throws {
        try await withQueue { queue in
            #expect(await queue.pending().isEmpty)
            #expect(queue.listedSessionIDs().isEmpty)

            try FileManager.default.createDirectory(at: queue.directory, withIntermediateDirectories: true)
            for name in ["notes.txt", "12_not-a-uuid.json", ".DS_Store", "x_\(UUID().uuidString).json"] {
                try Data().write(to: queue.directory.appending(path: name))
            }
            #expect(await WatchWalkQueue(directory: queue.directory).pending().isEmpty)
            #expect(queue.listedSessionIDs().isEmpty)
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
    }
}
