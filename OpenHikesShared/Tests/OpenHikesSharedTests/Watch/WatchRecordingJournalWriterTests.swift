//
//  WatchRecordingJournalWriterTests.swift
//  OpenHikesSharedTests
//

import Foundation
@testable import OpenHikesShared
import Testing

@Suite("Watch recording journal writer")
struct WatchRecordingJournalWriterTests {
    @Test("Fixes still waiting are not on disk until something writes them")
    func waitingFixesAreNotYetDurable() throws {
        try withWriter { writer in
            try writer.begin(Fixture.header)
            try writer.record(.fix(Fixture.fix(step: 0)), at: Fixture.time(step: 0))
            try writer.record(.fix(Fixture.fix(step: 1)), at: Fixture.time(step: 1))
            #expect(try #require(try writer.file.recover()).accumulator.fixes.isEmpty)

            try writer.flush()
            #expect(try #require(try writer.file.recover()).accumulator.fixes.count == 2)
        }
    }

    @Test("A pause takes the fixes before it to disk with it")
    func pauseMakesTheFixesDurable() throws {
        try withWriter { writer in
            try writer.begin(Fixture.header)
            try writer.record(.fix(Fixture.fix(step: 0)), at: Fixture.time(step: 0))
            try writer.record(.fix(Fixture.fix(step: 1)), at: Fixture.time(step: 1))
            try writer.record(.paused(Fixture.time(step: 2)), at: Fixture.time(step: 2))

            let recovered = try #require(try writer.file.recover())
            #expect(recovered.accumulator.fixes.count == 2)
            #expect(recovered.wasPaused)
        }
    }

    @Test("A new recording does not inherit the last one's waiting fixes")
    func beginForgetsWaitingFixes() throws {
        try withWriter { writer in
            try writer.begin(Fixture.header)
            try writer.record(.fix(Fixture.fix(step: 0)), at: Fixture.time(step: 0))

            let next = WatchRecordingJournalHeader(sessionID: UUID(), startedAt: Fixture.time(step: 5))
            try writer.begin(next)
            try writer.flush()
            let recovered = try #require(try writer.file.recover())
            #expect(recovered.header == next)
            #expect(recovered.accumulator.fixes.isEmpty)
        }
    }

    @Test("A closed journal leaves nothing to recover or to write later")
    func closeRemovesEverything() throws {
        try withWriter { writer in
            try writer.begin(Fixture.header)
            try writer.record(.fix(Fixture.fix(step: 0)), at: Fixture.time(step: 0))
            writer.close()
            #expect(try writer.file.recover() == nil)
            // Nothing was left waiting to be flushed into a journal that no
            // longer has a header.
            try writer.flush()
            #expect(!FileManager.default.fileExists(atPath: writer.file.url.path))
        }
    }

    @Test("A batch a failed write left waiting reaches disk with the next write")
    func failedWriteKeepsItsBatch() throws {
        try withWriter { writer in
            try writer.begin(Fixture.header)
            let count = WatchRecordingJournalBuffer.maximumPendingFixes
            var failedWrites = 0
            try withJournalMissing(writer.file) {
                for step in 0..<count {
                    do {
                        try writer.record(.fix(Fixture.fix(step: step)), at: Fixture.time(step: step))
                    } catch {
                        failedWrites += 1
                    }
                }
            }
            #expect(failedWrites > 0)
            try writer.record(.paused(Fixture.time(step: count)), at: Fixture.time(step: count))

            let recovered = try #require(try writer.file.recover())
            #expect(recovered.accumulator.fixes.count == count)
            #expect(recovered.wasPaused)
        }
    }

    @Test("A failed resume retries on each fix until it reaches disk")
    func failedResumeRetriesWithTheNextFix() throws {
        try withWriter { writer in
            try writer.begin(Fixture.header)
            try writer.record(.fix(Fixture.fix(step: 0)), at: Fixture.time(step: 0))
            try writer.record(.paused(Fixture.time(step: 1)), at: Fixture.time(step: 1))
            try withJournalMissing(writer.file) {
                #expect(throws: (any Error).self) {
                    try writer.record(.resumed(Fixture.time(step: 2)), at: Fixture.time(step: 2))
                }
                #expect(throws: (any Error).self) {
                    try writer.record(.fix(Fixture.fix(step: 3)), at: Fixture.time(step: 3))
                }
            }
            try writer.record(.fix(Fixture.fix(step: 4)), at: Fixture.time(step: 4))

            let recovered = try #require(try writer.file.recover())
            #expect(!recovered.wasPaused)
            #expect(recovered.accumulator.fixes.count == 3)
            #expect(recovered.accumulator.fixes.dropFirst().first?.resumesAfterPause == true)
            #expect(recovered.lastRecordedAt == Fixture.time(step: 4))
        }
    }

    @Test("A pause and resume recorded together survive a failed write together")
    func failedWriteKeepsPauseAndResume() throws {
        try withWriter { writer in
            try writer.begin(Fixture.header)
            try writer.record(.fix(Fixture.fix(step: 0)), at: Fixture.time(step: 0))
            try withJournalMissing(writer.file) {
                #expect(throws: (any Error).self) {
                    let breakAt = Fixture.time(step: 1)
                    try writer.record(.paused(breakAt), .resumed(breakAt), at: breakAt)
                }
            }
            try writer.record(.fix(Fixture.fix(step: 2)), at: Fixture.time(step: 2))

            let recovered = try #require(try writer.file.recover())
            #expect(recovered.accumulator.fixes.count == 2)
            #expect(recovered.accumulator.fixes.last?.resumesAfterPause == true)
            #expect(!recovered.wasPaused)
            #expect(recovered.lastRecordedAt == Fixture.time(step: 2))
        }
    }

    @Test("A header the disk refused is written ahead of the next line, once the disk takes it")
    func refusedHeaderIsWrittenWithTheNextLine() throws {
        try withWriter { writer in
            // A file where the journal's directory goes, so the header is refused.
            let directory = writer.file.url.deletingLastPathComponent()
            try Data().write(to: directory)
            #expect(throws: (any Error).self) { try writer.begin(Fixture.header) }
            #expect(throws: (any Error).self) {
                try writer.record(.fix(Fixture.fix(step: 0)), at: Fixture.time(step: 0))
            }
            try FileManager.default.removeItem(at: directory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            // One fix, well short of a batch: a recording with no journal at
            // all is not one to keep waiting.
            try writer.record(.fix(Fixture.fix(step: 1)), at: Fixture.time(step: 1))

            let recovered = try #require(try writer.file.recover())
            #expect(recovered.header == Fixture.header)
            #expect(recovered.accumulator.fixes.count == 2)
        }
    }

    @Test("Lines refused behind a header that landed go with the next line, not the next batch")
    func linesBehindALandedHeaderStayDue() throws {
        try withWriter { writer in
            let directory = writer.file.url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data().write(to: writer.file.url)
            try withJournalReadOnly(writer.file) {
                try withNothingNewIn(directory) {
                    #expect(throws: (any Error).self) { try writer.begin(Fixture.header) }
                }
                // An atomic write keeps the mode of the file it replaces, so
                // the header lands and the line behind it is refused.
                #expect(throws: (any Error).self) {
                    try writer.record(.fix(Fixture.fix(step: 0)), at: Fixture.time(step: 0))
                }
                let headerOnly = try #require(try writer.file.recover())
                #expect(headerOnly.header == Fixture.header)
                #expect(headerOnly.accumulator.fixes.isEmpty)
            }

            // One more fix, well short of a batch.
            try writer.record(.fix(Fixture.fix(step: 1)), at: Fixture.time(step: 1))

            let recovered = try #require(try writer.file.recover())
            #expect(recovered.header == Fixture.header)
            #expect(recovered.accumulator.fixes.count == 2)
        }
    }

    @Test("A new recording's lines never go under the last recording's header")
    func linesWaitForTheirOwnHeader() throws {
        try withWriter { writer in
            try writer.begin(Fixture.header)
            try writer.record(.fix(Fixture.fix(step: 0)), at: Fixture.time(step: 0))
            try writer.flush()

            let next = WatchRecordingJournalHeader(sessionID: UUID(), startedAt: Fixture.time(step: 5))
            try withNothingNewIn(writer.file.url.deletingLastPathComponent()) {
                #expect(throws: (any Error).self) { try writer.begin(next) }
                #expect(throws: (any Error).self) {
                    try writer.record(.fix(Fixture.fix(step: 6)), at: Fixture.time(step: 6))
                }
            }
            // The last journal could still be appended to, and was left alone.
            let earlier = try #require(try writer.file.recover())
            #expect(earlier.header == Fixture.header)
            #expect(earlier.accumulator.fixes.count == 1)

            try writer.record(.fix(Fixture.fix(step: 7)), at: Fixture.time(step: 7))
            let recovered = try #require(try writer.file.recover())
            #expect(recovered.header == next)
            #expect(recovered.accumulator.fixes.map(\.timestamp) == [Fixture.time(step: 6), Fixture.time(step: 7)])
        }
    }

    @Test("A recording taken up again after a relaunch goes on under the header already on disk")
    func recoveredJournalIsAppendedTo() throws {
        try withWriter { writer in
            try writer.begin(Fixture.header)
            try writer.record(.fix(Fixture.fix(step: 0)), at: Fixture.time(step: 0))
            try writer.flush()

            // What a relaunch holds: the same file, and a writer that never began.
            var relaunched = WatchRecordingJournalWriter(file: writer.file)
            #expect(try relaunched.file.recover() != nil)
            let breakAt = Fixture.time(step: 1)
            try relaunched.record(.paused(breakAt), .resumed(breakAt), at: breakAt)
            try relaunched.record(.fix(Fixture.fix(step: 2)), at: Fixture.time(step: 2))
            try relaunched.flush()

            let recovered = try #require(try relaunched.file.recover())
            #expect(recovered.header == Fixture.header)
            #expect(recovered.accumulator.fixes.count == 2)
            #expect(recovered.accumulator.fixes.last?.resumesAfterPause == true)
        }
    }

    /// Makes `directory` read-only for `body` and gives it back: a file
    /// already in it can still be written, and nothing new can be made there.
    private func withNothingNewIn(_ directory: URL, _ body: () throws -> Void) throws {
        let manager = FileManager.default
        try manager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        defer { try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path) }
        try body()
    }

    /// Makes the journal read-only for `body` and gives it back: every append
    /// in it throws, and an atomic write still replaces it.
    private func withJournalReadOnly(_ file: WatchRecordingJournalFile, _ body: () throws -> Void) throws {
        let manager = FileManager.default
        try manager.setAttributes([.posixPermissions: 0o444], ofItemAtPath: file.url.path)
        defer { try? manager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.url.path) }
        try body()
    }

    /// Moves the journal aside for `body`, so every append in it throws, and
    /// puts it back.
    private func withJournalMissing(_ file: WatchRecordingJournalFile, _ body: () throws -> Void) throws {
        let aside = file.url.appendingPathExtension("aside")
        try FileManager.default.moveItem(at: file.url, to: aside)
        defer { try? FileManager.default.moveItem(at: aside, to: file.url) }
        try body()
    }

    private func withWriter(_ body: (inout WatchRecordingJournalWriter) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "writer-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        var writer = WatchRecordingJournalWriter(
            file: WatchRecordingJournalFile(url: directory.appending(path: "recording.jsonl"))
        )
        try body(&writer)
    }

    private enum Fixture {
        static let start = Date(timeIntervalSince1970: 1_700_000_000)
        static let header = WatchRecordingJournalHeader(
            sessionID: UUID(uuidString: "77777777-7777-7777-7777-777777777777") ?? UUID(),
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
