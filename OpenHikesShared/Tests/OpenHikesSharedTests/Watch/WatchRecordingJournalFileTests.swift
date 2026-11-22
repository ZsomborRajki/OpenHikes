//
//  WatchRecordingJournalFileTests.swift
//  OpenHikesSharedTests
//

import Foundation
@testable import OpenHikesShared
import Testing

@Suite("Watch recording journal file")
struct WatchRecordingJournalFileTests {
    @Test("What is appended is what is recovered")
    func appendedLinesAreRecovered() throws {
        try withJournal { journal in
            try journal.begin(Fixture.header)
            try journal.append([.fix(Fixture.fix(step: 0)), .fix(Fixture.fix(step: 1))])
            try journal.append([.paused(Fixture.time(step: 2))])

            let recovered = try #require(try journal.recover())
            #expect(recovered.header == Fixture.header)
            #expect(recovered.accumulator.fixes.count == 2)
            #expect(recovered.wasPaused)
        }
    }

    @Test("A write killed halfway is cut off, so the next append still reads")
    func tornTailIsTruncatedBeforeTheNextAppend() throws {
        try withJournal { journal in
            try journal.begin(Fixture.header)
            try journal.append([.fix(Fixture.fix(step: 0)), .fix(Fixture.fix(step: 1))])
            // What a process killed mid-`write` leaves behind.
            let torn = try WatchRecordingJournalEntry.fix(Fixture.fix(step: 2)).line()
            let handle = try FileHandle(forWritingTo: journal.url)
            try handle.seekToEnd()
            try handle.write(contentsOf: torn.prefix(torn.count - 7))
            try handle.close()

            #expect(try #require(try journal.recover()).accumulator.fixes.count == 2)
            // Without the cut this line would be glued onto the torn one, and
            // lost with it.
            try journal.append([.fix(Fixture.fix(step: 3))])
            #expect(try #require(try journal.recover()).accumulator.fixes.count == 3)
        }
    }

    @Test("A new recording's header replaces the last journal whole")
    func beginReplacesTheLastJournal() throws {
        try withJournal { journal in
            try journal.begin(Fixture.header)
            try journal.append([.fix(Fixture.fix(step: 0)), .fix(Fixture.fix(step: 1))])

            let next = WatchRecordingJournalHeader(sessionID: UUID(), startedAt: Fixture.time(step: 9))
            try journal.begin(next)
            let recovered = try #require(try journal.recover())
            #expect(recovered.header == next)
            #expect(recovered.accumulator.fixes.isEmpty)
        }
    }

    @Test("Lines with no journal to go on are refused, not orphaned")
    func appendWithoutBeginThrows() throws {
        try withJournal { journal in
            #expect(throws: (any Error).self) {
                try journal.append([.fix(Fixture.fix(step: 0))])
            }
            let recovered = try journal.recover()
            #expect(recovered == nil)
        }
    }

    @Test("A removed journal recovers nothing")
    func removedJournalRecoversNothing() throws {
        try withJournal { journal in
            try journal.begin(Fixture.header)
            try journal.remove()
            #expect(try journal.recover() == nil)
        }
    }

    /// Answered `nil`, a journal that would not read was taken for none, and
    /// the next Start wrote over what may have been the only copy of a walk
    /// (#1573). A file with no permissions is one that is there and refuses
    /// to be read.
    @Test("A journal that is there and cannot be read throws, and reads whole once it can")
    func unreadableJournalThrows() throws {
        try withJournal { journal in
            try journal.begin(Fixture.header)
            try journal.append([.fix(Fixture.fix(step: 0)), .fix(Fixture.fix(step: 1))])
            let manager = FileManager.default
            try manager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: journal.url.path)

            #expect(throws: CocoaError.self) { try journal.recover() }

            try manager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: journal.url.path)
            let recovered = try #require(try journal.recover())
            #expect(recovered.header == Fixture.header)
            #expect(recovered.accumulator.fixes.count == 2)
        }
    }

    /// A removal the disk refused used to read as done, so a hiker's Discard
    /// went back to Start with the walk still on disk, to be offered again at
    /// the next launch (#1573). A directory that takes no changes refuses the
    /// removal and still lets the journal be read.
    @Test("A journal the disk will not remove throws and is still there; one already gone does not throw")
    func refusedRemovalThrows() throws {
        try withJournal { journal in
            try journal.remove()
            try journal.begin(Fixture.header)
            let manager = FileManager.default
            let directory = journal.url.deletingLastPathComponent().path
            try manager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory)
            defer { try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory) }

            #expect(throws: CocoaError.self) { try journal.remove() }
            #expect(try journal.recover()?.header == Fixture.header)

            try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory)
            try journal.remove()
            #expect(try journal.recover() == nil)
        }
    }

    private func withJournal(_ body: (WatchRecordingJournalFile) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "journal-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(WatchRecordingJournalFile(url: directory.appending(path: "recording.jsonl")))
    }

    private enum Fixture {
        static let start = Date(timeIntervalSince1970: 1_700_000_000)
        static let header = WatchRecordingJournalHeader(
            sessionID: UUID(uuidString: "66666666-6666-6666-6666-666666666666") ?? UUID(),
            startedAt: start
        )

        static func time(step: Int) -> Date {
            start.addingTimeInterval(Double(step) * 8)
        }

        static func fix(step: Int) -> WatchRecordedFix {
            WatchRecordedFix(
                latitude: 47.55 + Double(step) * 0.0001,
                longitude: 12.90,
                timestamp: time(step: step),
                horizontalAccuracy: 5
            )
        }
    }
}
