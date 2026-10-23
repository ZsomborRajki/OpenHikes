//
//  WatchWalkQueue.swift
//  OpenHikesShared
//
//  The watch's finished walks that the phone has not confirmed yet, on disk.
//
//  ## A count is not a read
//
//  The queue grows exactly when the phone is out of reach, and every walk on
//  it is a whole recording — six hours at a fix every two seconds is twelve
//  thousand fixes. Answering "how many are waiting?" or "which goes first?" by
//  decoding every file made each new walk cost a decode of every older one,
//  and a batch of receipts decoded shrinking copies of the same queue, all on
//  the main actor. So both are answered from the file *names*: a walk's file
//  is named for when it ended and its session, and the index is a directory
//  listing. A walk is read only when it is about to be sent.
//
//  A file written before this naming, `<session>.json`, is decoded once to
//  learn when it ended and renamed, so it costs that once rather than at every
//  launch.
//
//  ## Off the main actor
//
//  Writing a walk encodes every fix, and reading one decodes every fix. An
//  actor is the serial boundary that does both away from the screen, in the
//  order they were asked for: a receipt's removal can never land under the
//  write it confirms.
//
//  ## What has not changed
//
//  A walk is on disk before anything is told it exists, and it leaves only on a
//  ``WatchWalkReceipt`` — see `WatchStore` for why that ordering is the whole
//  design. ``enqueue(_:)`` answers only once the write has landed, so a caller
//  that awaits it can call the walk saved, and every write is `.atomic`.
//
//  Here rather than in `WatchStore` so `swift test` reaches it on the host: the
//  watch has no test bundle — see ``WatchWalkAccumulator``'s header.
//

import Foundation
import OSLog

/// The walks waiting for the phone, as the queue stood after one of its calls.
public struct WatchQueuedWalks: Sendable, Equatable {
    /// Oldest first, which is the order they should be offered in: a hiker who
    /// has been out of range for two walks wants yesterday's in their library
    /// as much as today's, and a queue that sent the newest first would leave
    /// the older one behind whenever the link closed again mid-drain.
    public let sessionIDs: [UUID]
    /// Goes up with every change to the queue, so a caller holding answers
    /// that came back out of order can keep the latest — see ``isNewer(than:)``.
    public let revision: Int

    public var count: Int { sessionIDs.count }
    public var isEmpty: Bool { sessionIDs.isEmpty }

    /// Whether this describes the queue at least as late as `other` does.
    ///
    /// Answers are awaited from separate tasks, and nothing promises they
    /// resume in the order they were asked. A count taken before a receipt
    /// and applied after it would show a walk that has gone.
    public func isNewer(than other: Self?) -> Bool {
        guard let other else { return true }
        return revision >= other.revision
    }
}

/// The disk queue of finished walks, indexed by file name.
public actor WatchWalkQueue {
    private static let logger = Logger(subsystem: "OpenHikesWatch", category: "Store")

    nonisolated public let directory: URL
    /// Every queued walk by session, built from a directory listing the first
    /// time anything is asked — see ``isIndexed``. A walk that will not
    /// decode stays here, uncounted, so a fresh copy of it can replace its
    /// file rather than sit beside it.
    private var entries: [UUID: Entry] = [:]
    private var isIndexed = false
    private var revision = 0

    public init(directory: URL) {
        self.directory = directory
    }

    // MARK: Asking

    /// What is waiting, without reading any of it.
    public func pending() -> WatchQueuedWalks {
        snapshot(of: index())
    }

    /// Reads one walk, for sending.
    ///
    /// `nil` for a walk not on the queue, or one that cannot be read. A file
    /// that reads but does not decode never will, so it stops counting for
    /// the rest of this process — counted, it would be a hike waiting for an
    /// iPhone forever — but stays on disk. One that cannot be read at all is
    /// kept, because that can pass.
    public func walk(_ sessionID: UUID) -> WatchRecordedWalk? {
        guard let entry = index()[sessionID], !entry.isUndecodable else { return nil }
        let url = url(of: entry.fileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let walk = Self.decode(data, named: entry.fileName) else {
            entries[sessionID]?.isUndecodable = true
            revision += 1
            return nil
        }
        return walk
    }

    /// The sessions with a file on the queue, from the names alone.
    ///
    /// Synchronous, for the one caller that has to decide before anything can
    /// wait: a recorder that finds a journal at launch, and must know before
    /// the first frame whether its walk is already queued or a hiker's Start
    /// could write over the only copy. A listing is cheap at any queue length.
    /// Read beside the actor rather than through it, which is safe only
    /// because nothing has written to the queue that early in the process.
    ///
    /// A name is not a walk, so a session listed here is only *probably*
    /// queued — ``WatchRecordingRecovery/confirming(_:on:)`` reads it before
    /// a journal is let go. A listing that fails answers empty, which offers
    /// the journal: the side that keeps a copy.
    nonisolated public func listedSessionIDs() -> Set<UUID> {
        Set(((try? Self.fileNames(in: directory)) ?? []).compactMap { Entry.Name(parsing: $0)?.sessionID })
    }

    // MARK: Changing

    /// Puts a walk on the queue, and answers once it is on disk.
    ///
    /// `nil` when the write failed, because the caller has a walk in hand and
    /// nothing else to do with it: a walk that could not be written has to be
    /// said out loud rather than sent hopefully and forgotten.
    public func enqueue(_ walk: WatchRecordedWalk) -> WatchQueuedWalks? {
        var updated = index()
        let entry = Entry(sessionID: walk.sessionID, endedAt: walk.endedAt)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(walk).write(to: url(of: entry.fileName), options: .atomic)
        } catch {
            Self.logger.error(
                """
                \(entry.fileName, privacy: .public) could not be written: \
                \(error.localizedDescription, privacy: .public)
                """
            )
            return nil
        }
        // The same session written again under another name — a walk saved
        // with a different end — leaves one file, not two.
        if let previous = updated[walk.sessionID], previous.fileName != entry.fileName {
            try? FileManager.default.removeItem(at: url(of: previous.fileName))
        }
        updated[walk.sessionID] = entry
        entries = updated
        revision += 1
        return snapshot(of: updated)
    }

    /// Takes a walk off the queue, which only a receipt from the phone does.
    public func remove(_ sessionID: UUID) -> WatchQueuedWalks {
        var updated = index()
        if let entry = updated.removeValue(forKey: sessionID) {
            try? FileManager.default.removeItem(at: url(of: entry.fileName))
            entries = updated
            revision += 1
        }
        return snapshot(of: updated)
    }

    // MARK: The index

    private struct Entry {
        /// What a file's name says about the walk in it.
        struct Name {
            let sessionID: UUID
            /// `nil` for a file named before the queue kept an index.
            let endedAt: Date?

            /// `<milliseconds since 1970>_<session>.json`, or the older
            /// `<session>.json`.
            init?(parsing fileName: String) {
                guard fileName.hasSuffix(".json") else { return nil }
                let stem = fileName.dropLast(".json".count)
                let parts = stem.split(separator: "_", maxSplits: 1)
                switch parts.count {
                case 1:
                    guard let parsed = UUID(uuidString: String(parts[0])) else { return nil }
                    sessionID = parsed
                    endedAt = nil
                case 2:
                    guard let milliseconds = Int64(parts[0]),
                          let parsed = UUID(uuidString: String(parts[1]))
                    else { return nil }
                    sessionID = parsed
                    endedAt = Entry.date(milliseconds: milliseconds)
                default:
                    return nil
                }
            }
        }

        let sessionID: UUID
        /// To the millisecond the name carries, so a walk sorts the same
        /// whether it was enqueued in this process or listed from disk.
        let endedAt: Date
        /// Its own name, except for an older file whose rename failed or
        /// that would not decode.
        var fileName: String
        /// Read, and found not to be a walk. Never counted or read again, but
        /// kept so the next write of its session removes the file.
        var isUndecodable = false

        init(sessionID: UUID, endedAt: Date) {
            let milliseconds = Int64((endedAt.timeIntervalSince1970 * 1000).rounded(.down))
            self.sessionID = sessionID
            self.endedAt = Self.date(milliseconds: milliseconds)
            fileName = "\(milliseconds)_\(sessionID.uuidString).json"
        }

        /// An older file that read but did not decode, so has no end to name.
        init(undecodable fileName: String, sessionID: UUID) {
            self.sessionID = sessionID
            endedAt = .distantPast
            self.fileName = fileName
            isUndecodable = true
        }

        static func date(milliseconds: Int64) -> Date {
            Date(timeIntervalSince1970: Double(milliseconds) / 1000)
        }
    }

    private func index() -> [UUID: Entry] {
        if isIndexed { return entries }
        // Left unindexed when the listing fails, so the next call lists
        // again. Marked indexed, an empty answer from a directory that could
        // not be read would hide every walk on it until the next launch.
        let fileNames: [String]
        do {
            fileNames = try Self.fileNames(in: directory)
        } catch {
            Self.logger.error("The queue could not be listed: \(error.localizedDescription, privacy: .public)")
            return entries
        }
        var built: [UUID: Entry] = [:]
        for fileName in fileNames {
            guard let name = Entry.Name(parsing: fileName) else { continue }
            let entry = if let endedAt = name.endedAt {
                Entry(sessionID: name.sessionID, endedAt: endedAt)
            } else {
                adopt(olderFile: fileName, sessionID: name.sessionID)
            }
            // A walk beside a file of its session that is not one — left by
            // a process that died between writing the one and removing the
            // other — is the one to keep.
            guard let entry, built[entry.sessionID]?.isUndecodable ?? true else { continue }
            built[entry.sessionID] = entry
        }
        entries = built
        isIndexed = true
        // A count from before the listing, or from one that failed, is not
        // as late as this one.
        revision += 1
        return built
    }

    /// Reads a file named before the index once, and renames it so the next
    /// launch need not. One that reads but does not decode is indexed
    /// uncounted, like any other — see ``Entry/isUndecodable``. One that
    /// cannot be read is left out.
    private func adopt(olderFile fileName: String, sessionID: UUID) -> Entry? {
        guard let data = try? Data(contentsOf: url(of: fileName)) else { return nil }
        guard let walk = Self.decode(data, named: fileName) else {
            return Entry(undecodable: fileName, sessionID: sessionID)
        }
        var entry = Entry(sessionID: walk.sessionID, endedAt: walk.endedAt)
        do {
            try FileManager.default.moveItem(at: url(of: fileName), to: url(of: entry.fileName))
        } catch {
            entry.fileName = fileName
        }
        return entry
    }

    private func snapshot(of entries: [UUID: Entry]) -> WatchQueuedWalks {
        let ordered = entries.values.filter { !$0.isUndecodable }.sorted { lhs, rhs in
            lhs.endedAt != rhs.endedAt
                ? lhs.endedAt < rhs.endedAt
                : lhs.sessionID.uuidString < rhs.sessionID.uuidString
        }
        return WatchQueuedWalks(sessionIDs: ordered.map(\.sessionID), revision: revision)
    }

    // MARK: Files

    private func url(of fileName: String) -> URL {
        directory.appendingPathComponent(fileName)
    }

    /// Throws when the directory is there and could not be listed, which is
    /// not the same answer as an empty queue.
    private static func fileNames(in directory: URL) throws -> [String] {
        do {
            return try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))
        } catch CocoaError.fileReadNoSuchFile {
            // Nothing has been queued on this watch yet.
            return []
        }
    }

    private static func decode(_ data: Data, named fileName: String) -> WatchRecordedWalk? {
        do {
            return try JSONDecoder().decode(WatchRecordedWalk.self, from: data)
        } catch {
            // Said rather than swallowed: a file that can never be decoded is
            // a walk that will never reach the phone, and a cost that
            // presents as nothing at all is worth being able to see.
            logger.error(
                """
                \(fileName, privacy: .public) could not be read: \
                \(error.localizedDescription, privacy: .public)
                """
            )
            return nil
        }
    }
}
