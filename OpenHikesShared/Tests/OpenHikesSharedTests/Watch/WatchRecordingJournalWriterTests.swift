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
            #expect(try #require(writer.file.recover()).accumulator.fixes.isEmpty)

            try writer.flush()
            #expect(try #require(writer.file.recover()).accumulator.fixes.count == 2)
        }
    }

    @Test("A pause takes the fixes before it to disk with it")
    func pauseMakesTheFixesDurable() throws {
        try withWriter { writer in
            try writer.begin(Fixture.header)
            try writer.record(.fix(Fixture.fix(step: 0)), at: Fixture.time(step: 0))
            try writer.record(.fix(Fixture.fix(step: 1)), at: Fixture.time(step: 1))
            try writer.record(.paused(Fixture.time(step: 2)), at: Fixture.time(step: 2))

            let recovered = try #require(writer.file.recover())
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
            let recovered = try #require(writer.file.recover())
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
            #expect(writer.file.recover() == nil)
            // Nothing was left waiting to be flushed into a journal that no
            // longer has a header.
            try writer.flush()
            #expect(!FileManager.default.fileExists(atPath: writer.file.url.path))
        }
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
