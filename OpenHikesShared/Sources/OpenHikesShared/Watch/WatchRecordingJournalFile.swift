//
//  WatchRecordingJournalFile.swift
//  OpenHikesShared
//
//  The one file a watch recording's journal lives in.
//
//  Here rather than in `WatchStore` so the parts that decide anything — the
//  append after a torn tail, the header that starts a fresh file — run under
//  `swift test` on the host. The watch has no test bundle; see
//  ``WatchWalkAccumulator``'s header for why.
//
//  One recording at a time, which is all a watch has: a new header replaces
//  whatever was here, so a recording is never started over a journal the
//  hiker has not answered for — ``WatchRecordingRecovery`` is asked first.
//

import Foundation

public struct WatchRecordingJournalFile: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// Starts a fresh journal for a new recording, replacing any other.
    ///
    /// `.atomic`, so there is never a moment when the file is empty or holds
    /// half a header: it is the old journal or the new one.
    public func begin(_ header: WatchRecordingJournalHeader) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try WatchRecordingJournalEntry.began(header).line().write(to: url, options: .atomic)
    }

    /// Appends lines to the journal ``begin(_:)`` started.
    ///
    /// Not atomic, and does not need to be: a kill mid-write leaves a torn
    /// last line, which ``recover()`` cuts off. Refuses rather than creates a
    /// missing file, because a journal without its header is one no recovery
    /// would read.
    ///
    /// A write that throws is cut back to where it started. Half a batch left
    /// on disk would be a torn line with the retry appended after it, and a
    /// recovery stops at the first line that does not decode — so it would
    /// lose the retry and everything written after it.
    public func append(_ entries: [WatchRecordingJournalEntry]) throws {
        guard !entries.isEmpty else { return }
        // Opened before anything is encoded. A journal whose header never
        // landed refuses every write for the rest of the walk, and the
        // writer retries with every line while what it has waiting grows, so
        // encoding first would encode the whole backlog again per fix only to
        // be refused.
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        var data = Data()
        for entry in entries { data.append(try entry.line()) }
        let end = try handle.seekToEnd()
        do {
            try handle.write(contentsOf: data)
        } catch {
            try? handle.truncate(atOffset: end)
            throw error
        }
    }

    /// The recording this journal holds, with a torn tail cut off so the next
    /// ``append(_:)`` lands after a whole line.
    public func recover() -> WatchRecoveredRecording? {
        guard let data = try? Data(contentsOf: url),
              let (recording, validByteCount) = WatchRecoveredRecording.replaying(data)
        else { return nil }
        if validByteCount < data.count,
           let handle = try? FileHandle(forWritingTo: url) {
            try? handle.truncate(atOffset: UInt64(validByteCount))
            try? handle.close()
        }
        return recording
    }

    /// Removes the journal, once its walk is on the outbound queue or the
    /// hiker has thrown it away.
    public func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// A recording's journal as the recorder holds it: the file, and the lines
/// waiting to go into it.
///
/// Every write can throw, and the recorder logs a throw and carries on. The
/// journal is insurance against the process dying; a recording refused or
/// stopped for want of it would lose the walk the insurance is for. A failed
/// write loses nothing either: its lines stay waiting, in order, and go to
/// disk with the next write that succeeds. Until then they are missing only
/// from a recovery — the accumulator still has them, and a Stop keeps them.
public struct WatchRecordingJournalWriter: Sendable {
    public let file: WatchRecordingJournalFile
    private var buffer = WatchRecordingJournalBuffer()

    public init(file: WatchRecordingJournalFile) {
        self.file = file
    }

    /// Starts a fresh journal, and forgets anything the last one had waiting.
    public mutating func begin(_ header: WatchRecordingJournalHeader) throws {
        buffer = WatchRecordingJournalBuffer()
        try file.begin(header)
    }

    /// Writes lines down, now or with the next batch — see
    /// ``WatchRecordingJournalBuffer``.
    ///
    /// Every line is waiting before anything is written, so lines that belong
    /// together — a recovery's pause and resume — are kept together by a
    /// write that throws, rather than the first kept and the rest never added.
    public mutating func record(_ entries: WatchRecordingJournalEntry..., at date: Date) throws {
        var isDue = false
        for entry in entries {
            isDue = buffer.add(entry, at: date) || isDue
        }
        if isDue { try flush() }
    }

    /// Writes everything still waiting, and keeps it waiting if that throws.
    public mutating func flush() throws {
        try file.append(buffer.pending)
        buffer.written()
    }

    /// Lets the journal go, once its walk is on the outbound queue or the
    /// hiker has thrown it away.
    public mutating func close() {
        buffer = WatchRecordingJournalBuffer()
        file.remove()
    }
}
