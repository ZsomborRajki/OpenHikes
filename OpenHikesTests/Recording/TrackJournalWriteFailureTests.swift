//
//  TrackJournalWriteFailureTests.swift
//  OpenHikesTests
//
//  A flush that fails keeps its points and retries them. These suites make
//  sure the retry lands where the failed write started, not after whatever
//  part of it reached the disk: the file is fixed-width, so one torn record
//  ahead of a retried batch moves every record behind it to the wrong offset
//  and recovery reads back garbage fixes.
//

import Foundation
@testable import OpenHikes
import Synchronization
import Testing

@Suite("Track journal write failures")
struct TrackJournalWriteFailureTests {
    private let start = Date(timeIntervalSince1970: 1_750_000_000)

    private func sandbox() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "recording-journal-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    private func point(_ index: Int) -> RecordingPoint {
        RecordingPoint(
            latitude: 47.63 + Double(index) * 0.0001,
            longitude: 12.86,
            timestamp: start.addingTimeInterval(Double(index) * 10),
            horizontalAccuracy: 8,
            elevation: 600 + Double(index),
            flags: index == 1 ? .resumed : []
        )
    }

    private func journal(
        in directory: URL,
        faults: JournalFaults
    ) -> TrackJournal {
        TrackJournal(directory: directory, clock: TestClock(start).read) { url in
            try FaultyJournalHandle(url: url, faults: faults)
        }
    }

    private func fileSize(_ journal: TrackJournal) throws -> Int? {
        try FileManager.default.attributesOfItem(
            atPath: journal.journalURL.path
        )[.size] as? Int
    }

    /// What a fresh launch reads back, rather than what the open journal
    /// says about itself.
    private func recoveredPoints(in directory: URL) async throws -> [RecordingPoint] {
        try #require(
            try await TrackJournal(directory: directory).loadSession()
        ).points
    }

    private func expectSameFixes(
        _ actual: [RecordingPoint],
        _ expected: [RecordingPoint],
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(
            actual.map(\.timestamp) == expected.map(\.timestamp),
            "every fix once, in order",
            sourceLocation: sourceLocation
        )
        #expect(actual.map(\.latitude) == expected.map(\.latitude), sourceLocation: sourceLocation)
        #expect(actual.map(\.flags) == expected.map(\.flags), sourceLocation: sourceLocation)
    }

    @Test("a short write is cut back, so its retry and later fixes read back intact")
    func shortWriteRollsBack() async throws {
        let directory = try sandbox()
        defer { try? FileManager.default.removeItem(at: directory) }
        let faults = JournalFaults()
        let journal = journal(in: directory, faults: faults)
        try await journal.start(sessionID: UUID(), startedAt: start)
        try await journal.append(point(0))
        try await journal.append(point(1))

        // One whole record and 13 bytes of the next, then the disk refuses.
        faults.shortenNextWrite(keeping: TrackJournal.recordByteCount + 13)
        await #expect(throws: TrackJournalError.self) {
            try await journal.flush()
        }
        #expect(
            try fileSize(journal) == TrackJournal.headerByteCount,
            "the failed batch leaves nothing behind, not even its whole first record"
        )

        try await journal.flush()
        try await journal.append(point(2))
        try await journal.flush()

        let expected = [point(0), point(1), point(2)]
        expectSameFixes(try #require(try await journal.loadSession()).points, expected)
        try await journal.close()
        expectSameFixes(try await recoveredPoints(in: directory), expected)
    }

    @Test("a failed synchronize is cut back, so its retry writes each fix once")
    func failedSynchronizeRollsBack() async throws {
        let directory = try sandbox()
        defer { try? FileManager.default.removeItem(at: directory) }
        let faults = JournalFaults()
        let journal = journal(in: directory, faults: faults)
        try await journal.start(sessionID: UUID(), startedAt: start)
        try await journal.append(point(0))
        try await journal.flush()
        try await journal.append(point(1))
        try await journal.append(point(2))

        faults.failNextSynchronize()
        await #expect(throws: TrackJournalError.self) {
            try await journal.flush()
        }
        #expect(
            try fileSize(journal)
                == TrackJournal.headerByteCount + TrackJournal.recordByteCount
        )

        try await journal.flush()
        try await journal.close()
        expectSameFixes(
            try await recoveredPoints(in: directory),
            [point(0), point(1), point(2)]
        )
    }

    @Test("a torn tail that cannot be cut back refuses every write until it can")
    func failedRollbackRefusesWrites() async throws {
        let directory = try sandbox()
        defer { try? FileManager.default.removeItem(at: directory) }
        let faults = JournalFaults()
        let journal = journal(in: directory, faults: faults)
        try await journal.start(sessionID: UUID(), startedAt: start)
        try await journal.append(point(0))
        try await journal.append(point(1))

        let tornSize = TrackJournal.headerByteCount + TrackJournal.recordByteCount + 13
        faults.shortenNextWrite(keeping: TrackJournal.recordByteCount + 13)
        faults.failTruncations(2)
        await #expect(throws: TrackJournalError.self) {
            try await journal.flush()
        }
        #expect(try fileSize(journal) == tornSize)

        try await journal.append(point(2))
        await #expect(throws: TrackJournalError.self) {
            try await journal.flush()
        }
        #expect(
            try fileSize(journal) == tornSize,
            "nothing is written after a torn record"
        )

        try await journal.flush()
        try await journal.close()
        expectSameFixes(
            try await recoveredPoints(in: directory),
            [point(0), point(1), point(2)]
        )
    }
}

/// The failures the next calls on a ``FaultyJournalHandle`` make, each used
/// up as it fires.
nonisolated private final class JournalFaults: Sendable {
    private struct Pending {
        var shortWrite: Int?
        var synchronize = false
        var truncations = 0
    }

    private let pending = Mutex(Pending())

    func shortenNextWrite(keeping byteCount: Int) {
        pending.withLock { $0.shortWrite = byteCount }
    }

    func failNextSynchronize() {
        pending.withLock { $0.synchronize = true }
    }

    func failTruncations(_ count: Int) {
        pending.withLock { $0.truncations = count }
    }

    func takeShortWrite() -> Int? {
        pending.withLock { state in
            defer { state.shortWrite = nil }
            return state.shortWrite
        }
    }

    func takeSynchronize() -> Bool {
        pending.withLock { state in
            defer { state.synchronize = false }
            return state.synchronize
        }
    }

    func takeTruncation() -> Bool {
        pending.withLock { state in
            guard state.truncations > 0 else { return false }
            state.truncations -= 1
            return true
        }
    }
}

/// A real file handle that fails the way a full disk does: a write that puts
/// part of its bytes in the file before it throws, and a `synchronize()` that
/// throws after all of them went out.
nonisolated private final class FaultyJournalHandle: TrackJournalHandle {
    private let file: FileHandle
    private let faults: JournalFaults

    init(url: URL, faults: JournalFaults) throws {
        file = try FileHandle(forWritingTo: url)
        self.faults = faults
    }

    func seekToEnd() throws -> UInt64 {
        try file.seekToEnd()
    }

    func write(contentsOf data: Data) throws {
        guard let kept = faults.takeShortWrite() else {
            try file.write(contentsOf: data)
            return
        }
        try file.write(contentsOf: data.prefix(kept))
        throw CocoaError(.fileWriteOutOfSpace)
    }

    func synchronize() throws {
        try file.synchronize()
        if faults.takeSynchronize() { throw CocoaError(.fileWriteUnknown) }
    }

    func truncate(atOffset offset: UInt64) throws {
        if faults.takeTruncation() { throw CocoaError(.fileWriteUnknown) }
        try file.truncate(atOffset: offset)
    }

    func close() throws {
        try file.close()
    }
}
