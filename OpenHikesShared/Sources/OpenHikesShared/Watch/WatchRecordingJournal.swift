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
    /// A pause Auto-Pause made at a stop, from the moment the stop began,
    /// which is behind the lines before it: every fix after that moment was
    /// the stop's, and is taken back — see
    /// ``WatchWalkAccumulator/pause(since:)``. A line of its own rather than
    /// a cut of the file's tail, because the journal is only ever appended
    /// to; a replay reaches the boundary the recording showed.
    case autoPaused(Date)
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
    /// Whether that pause was one Auto-Pause made, which a relaunch under
    /// the recovered workout session takes up again.
    public var wasAutoPaused = false
    /// The last moment the journal can vouch for: the latest fix, pause or
    /// resume it holds, or the start when it holds none.
    public var lastRecordedAt: Date

    public var sessionID: UUID { header.sessionID }

    /// Rebuilds a recording from a journal's bytes, or `nil` when there is no
    /// header to rebuild one from.
    ///
    /// Each line is applied to the one recording in place. A copy taken per
    /// line, while the recording before it was still held, copied every fix
    /// kept so far on every fix: a replay that grew with the square of the
    /// walk, which the watch paid before its first frame (#1543).
    ///
    /// - Returns: the recording and how many leading bytes of `data` are
    ///   whole lines, so the caller can cut a torn tail off before appending
    ///   anything after it — a line appended to half a line would be one more
    ///   undecodable line, and would take every line after it down too.
    public static func replaying(_ data: Data) -> (recording: Self, validByteCount: Int)? {
        var lines = JournalLines(data)
        guard case .began(let header)? = lines.next() else { return nil }
        var recording = Self(
            header: header,
            accumulator: WatchWalkAccumulator(),
            wasPaused: false,
            lastRecordedAt: header.startedAt
        )
        var validByteCount = lines.consumedByteCount
        while let entry = lines.next(), recording.apply(entry) {
            validByteCount = lines.consumedByteCount
        }
        return (recording, validByteCount)
    }

    /// Applies one more line, or answers `false` and changes nothing for a
    /// line that has no business after the first — a second header is a
    /// journal nothing here wrote.
    private mutating func apply(_ entry: WatchRecordingJournalEntry) -> Bool {
        switch entry {
        case .began:
            return false
        case .fix(let fix):
            if fix.resumesAfterPause { accumulator.pause() }
            accumulator.accept(
                latitude: fix.latitude,
                longitude: fix.longitude,
                timestamp: fix.timestamp,
                horizontalAccuracy: fix.horizontalAccuracy,
                elevationMeters: fix.elevationMeters
            )
            lastRecordedAt = max(lastRecordedAt, fix.timestamp)
        case .paused(let date):
            accumulator.pause()
            wasPaused = true
            wasAutoPaused = false
            lastRecordedAt = max(lastRecordedAt, date)
        case .autoPaused(let date):
            accumulator.pause(since: date)
            wasPaused = true
            wasAutoPaused = true
            lastRecordedAt = max(lastRecordedAt, date)
        case .resumed(let date):
            wasPaused = false
            wasAutoPaused = false
            lastRecordedAt = max(lastRecordedAt, date)
        }
        return true
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

/// A journal's whole lines, decoded in order, up to the first that does not
/// decode or that no newline ends.
private struct JournalLines: IteratorProtocol {
    private let data: Data
    private var lineStart: Data.Index
    /// One for the whole journal rather than one a line.
    private let decoder = JSONDecoder()
    /// How many leading bytes of the journal the lines handed out so far fill.
    private(set) var consumedByteCount = 0

    init(_ data: Data) {
        self.data = data
        lineStart = data.startIndex
    }

    mutating func next() -> WatchRecordingJournalEntry? {
        guard let newline = data[lineStart...].firstIndex(of: WatchRecordingJournalEntry.newline),
              let entry = try? decoder.decode(WatchRecordingJournalEntry.self, from: data[lineStart..<newline])
        else { return nil }
        lineStart = data.index(after: newline)
        consumedByteCount = data.distance(from: data.startIndex, to: lineStart)
        return entry
    }
}

/// What to do with a journal found at launch.
public enum WatchRecordingRecovery: Sendable, Equatable {
    /// The walk already reached the outbound queue, and only the journal's
    /// removal was lost — whether it is still on the queue or the phone has
    /// confirmed it since. Offering it again would be offering it twice.
    case alreadyQueued
    /// No journal, or none that could be read.
    case nothing
    case offer(WatchRecoveredRecording)

    /// Reads and replays `journal`, cutting a torn tail off, and asks `queue`
    /// whether its walk already went — all of it off the main actor.
    ///
    /// A six-hour journal is tens of thousands of lines to decode, and the
    /// queue reads a whole walk to answer, so neither is work for the launch
    /// to wait on before its first frame. The recorder holds Start back
    /// until this answers instead: a Start before it would write a fresh
    /// journal over what may be the only copy of a walk.
    ///
    /// Stop writes the walk to the queue *before* it removes the journal, so
    /// a process killed between the two leaves both. The queue is the one
    /// that counts, because it is what the phone is sent. But a file named
    /// for the walk says it was written, not that it can still be read back:
    /// one that will not decode is never sent, and a journal let go beside it
    /// would be the hike lost. So the journal is offered unless the queue
    /// hands its walk back — one that cannot be read just now included,
    /// because offering a walk that is already queued costs the hiker a
    /// question, and the other mistake costs the walk.
    ///
    /// Or unless the phone has already confirmed it. The launch drain does
    /// not wait for this check, so the walk can cross and its receipt take
    /// it off the queue while the journal is still replaying. Offered then,
    /// Continue would carry on under a session the phone already holds, and
    /// the phone would drop everything after as a second arrival — see
    /// ``WatchWalkQueue/hasTaken(_:)``.
    @concurrent
    public static func checking(_ journal: WatchRecordingJournalFile, against queue: WatchWalkQueue) async -> Self {
        guard let recording = journal.recover() else { return .nothing }
        return await queue.hasTaken(recording.sessionID) ? .alreadyQueued : .offer(recording)
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
struct WatchRecordingJournalBuffer: Sendable, Equatable {
    /// At most this many fixes wait.
    static let maximumPendingFixes = 12
    /// And none waits longer than this, measured on the fixes' own clock.
    static let maximumPendingSeconds: TimeInterval = 30

    private(set) var pending: [WatchRecordingJournalEntry] = []
    private var oldestPendingAt: Date?
    private var isDue = false

    init() { /* nothing waiting */ }

    /// Adds a line. Returns whether ``pending`` is due to be written now —
    /// false while fixes are still allowed to wait.
    ///
    /// A due batch stays due until ``written()``. A failed pause or resume
    /// must retry with the next fix even below the count and time limits.
    mutating func add(_ entry: WatchRecordingJournalEntry, at date: Date) -> Bool {
        pending.append(entry)
        if case .fix = entry {
            let oldest = oldestPendingAt ?? date
            oldestPendingAt = oldest
            isDue = isDue || pending.count >= Self.maximumPendingFixes
                || date.timeIntervalSince(oldest) >= Self.maximumPendingSeconds
        } else {
            isDue = true
        }
        return isDue
    }

    /// Makes ``pending`` due whatever it holds, until ``written()``: lines a
    /// write was asked for go with the next line if that write throws,
    /// rather than waiting out the count and time limits again.
    mutating func makeDue() {
        isDue = true
    }

    /// Forgets everything waiting, once it is on disk. Not before: a write
    /// that throws leaves it all waiting for the next one.
    mutating func written() {
        pending = []
        oldestPendingAt = nil
        isDue = false
    }
}
