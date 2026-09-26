//
//  WatchRecordingJournal.swift
//  OpenHikesShared
//
//  What a watch recording writes down while it is happening, so a process
//  that dies mid-walk leaves the walk behind rather than nothing.
//
//  ## Why a journal, when the phone gets only finished walks
//
//  Because until Stop the accumulator is the only copy there is. The phone is
//  deliberately never told about a watch recording in progress — see
//  ``WatchRecordedWalk``'s header — and the watch throws its workout builder
//  away, so a crash, a reboot or a flat battery two hours in used to lose two
//  hours. The journal changes none of that ownership. It is the watch's own
//  scratch copy of the watch's own recording, it never crosses, and what
//  crosses is still one finished ``WatchRecordedWalk`` built from it.
//
//  ## Why the events, rather than the totals
//
//  A line per fix, per pause and per resume, replayed through a fresh
//  ``WatchWalkAccumulator`` on recovery. The totals are then the accumulator's
//  own arithmetic over the same inputs, which cannot disagree with the track
//  the way a stored total could; and appending one short line is the cheapest
//  write a watch can make, where rewriting a six-hour track every half minute
//  would be hundreds of megabytes of flash by the end of the walk.
//
//  ## A torn tail is expected, not corrupt
//
//  A process killed mid-append leaves half a line at the end. Recovery keeps
//  every whole line before the first one that does not decode and nothing
//  after it: the lines are written in order, so the first bad one is where the
//  durable prefix ends.
//

import Foundation

/// What a recording is, as its first journal line says.
public struct WatchRecordingJournalHeader: Codable, Sendable, Equatable {
    public var sessionID: UUID
    public var startedAt: Date
    public var trailHikeID: UUID?
    public var title: String?

    public init(sessionID: UUID, startedAt: Date, trailHikeID: UUID? = nil, title: String? = nil) {
        self.sessionID = sessionID
        self.startedAt = startedAt
        self.trailHikeID = trailHikeID
        self.title = title
    }
}

/// One line of a recording's journal.
public enum WatchRecordingJournalEntry: Codable, Sendable, Equatable {
    /// Always the first line, and only ever the first.
    case began(WatchRecordingJournalHeader)
    /// A fix the accumulator kept.
    case fix(WatchRecordedFix)
    case paused(Date)
    case resumed(Date)

    /// The line as it is appended: one JSON object and a newline.
    public func line() throws -> Data {
        var data = try JSONEncoder().encode(self)
        data.append(Self.newline)
        return data
    }

    static let newline = UInt8(ascii: "\n")
}

/// A recording rebuilt from its journal.
public struct WatchRecoveredRecording: Sendable, Equatable {
    public var header: WatchRecordingJournalHeader
    /// The accumulator the recording had when its last durable line was
    /// written — the same fixes, replayed through the same gates.
    public var accumulator: WatchWalkAccumulator
    /// Whether the last thing the hiker did was pause.
    public var wasPaused: Bool
    /// The last moment the journal can vouch for: the latest fix, pause or
    /// resume it holds, or the start when it holds none.
    public var lastRecordedAt: Date

    public var sessionID: UUID { header.sessionID }

    /// Rebuilds a recording from a journal's bytes, or `nil` when there is no
    /// header to rebuild one from.
    ///
    /// - Returns: the recording and how many leading bytes of `data` are
    ///   whole lines, so the caller can cut a torn tail off before appending
    ///   anything after it — a line appended to half a line would be one more
    ///   undecodable line, and would take every line after it down too.
    public static func replaying(_ data: Data) -> (recording: Self, validByteCount: Int)? {
        var recording: Self?
        var validByteCount = 0
        var lineStart = data.startIndex
        while let newline = data[lineStart...].firstIndex(of: WatchRecordingJournalEntry.newline) {
            guard let entry = try? JSONDecoder().decode(
                WatchRecordingJournalEntry.self,
                from: data[lineStart..<newline]
            ) else { break }
            if let current = recording {
                guard let next = current.applying(entry) else { break }
                recording = next
            } else {
                guard case .began(let header) = entry else { return nil }
                recording = Self(
                    header: header,
                    accumulator: WatchWalkAccumulator(),
                    wasPaused: false,
                    lastRecordedAt: header.startedAt
                )
            }
            lineStart = data.index(after: newline)
            validByteCount = data.distance(from: data.startIndex, to: lineStart)
        }
        return recording.map { ($0, validByteCount) }
    }

    /// The recording with one more line applied, or `nil` for a line that has
    /// no business after the first — a second header is a journal nothing
    /// here wrote.
    private func applying(_ entry: WatchRecordingJournalEntry) -> Self? {
        var next = self
        switch entry {
        case .began:
            return nil
        case .fix(let fix):
            if fix.resumesAfterPause { next.accumulator.pause() }
            next.accumulator.accept(
                latitude: fix.latitude,
                longitude: fix.longitude,
                timestamp: fix.timestamp,
                horizontalAccuracy: fix.horizontalAccuracy,
                elevationMeters: fix.elevationMeters
            )
            next.lastRecordedAt = max(lastRecordedAt, fix.timestamp)
        case .paused(let date):
            next.accumulator.pause()
            next.wasPaused = true
            next.lastRecordedAt = max(lastRecordedAt, date)
        case .resumed(let date):
            next.wasPaused = false
            next.lastRecordedAt = max(lastRecordedAt, date)
        }
        return next
    }

    /// The walk this recording had become when it was interrupted, or `nil`
    /// if it is not one worth keeping.
    ///
    /// It ends at ``lastRecordedAt`` rather than now. The time between the
    /// last durable line and the relaunch was not recorded, and a walk that
    /// ended "now" would claim hours of it.
    public func finishedWalk() -> WatchRecordedWalk? {
        accumulator.recordedWalk(
            sessionID: header.sessionID,
            startedAt: header.startedAt,
            endedAt: lastRecordedAt,
            trailHikeID: header.trailHikeID,
            title: header.title
        )
    }
}

/// What to do with a journal found at launch.
public enum WatchRecordingRecovery: Sendable, Equatable {
    /// The walk already reached the outbound queue, and only the journal's
    /// removal was lost. Offering it again would be offering it twice.
    case alreadyQueued
    /// No journal, or none that could be read.
    case nothing
    case offer(WatchRecoveredRecording)

    /// - Parameter queued: the session IDs already on the outbound queue.
    ///
    /// Stop writes the walk to the queue *before* it removes the journal, so
    /// a process killed between the two leaves both. The queue is the one
    /// that counts, because it is what the phone is sent.
    public static func resolve(_ recording: WatchRecoveredRecording?, queued: Set<UUID>) -> Self {
        guard let recording else { return .nothing }
        if queued.contains(recording.sessionID) { return .alreadyQueued }
        return .offer(recording)
    }
}

/// Journal lines waiting to be written, and when they are due.
///
/// Fixes wait. A hiker walking lays one down every few seconds, and a write
/// per fix is a write the recording does not need: losing the last half
/// minute to a crash costs a sliver of the line, which the phone draws as a
/// gap like any other. Everything else — the header, a pause, a resume — is
/// written at once with whatever fixes are waiting, because each one changes
/// what a recovery would do rather than merely how much of the line it has.
public struct WatchRecordingJournalBuffer: Sendable, Equatable {
    /// At most this many fixes wait.
    public static let maximumPendingFixes = 12
    /// And none waits longer than this, measured on the fixes' own clock.
    public static let maximumPendingSeconds: TimeInterval = 30

    public private(set) var pending: [WatchRecordingJournalEntry] = []
    private var oldestPendingAt: Date?

    public init() { /* nothing waiting */ }

    /// Adds a line. Returns what is due to be written now — empty while fixes
    /// are still allowed to wait.
    public mutating func add(_ entry: WatchRecordingJournalEntry, at date: Date) -> [WatchRecordingJournalEntry] {
        pending.append(entry)
        guard case .fix = entry else { return drain() }
        let oldest = oldestPendingAt ?? date
        oldestPendingAt = oldest
        let isDue = pending.count >= Self.maximumPendingFixes
            || date.timeIntervalSince(oldest) >= Self.maximumPendingSeconds
        return isDue ? drain() : []
    }

    /// Everything waiting, which the caller is now responsible for.
    public mutating func drain() -> [WatchRecordingJournalEntry] {
        defer {
            pending = []
            oldestPendingAt = nil
        }
        return pending
    }
}
