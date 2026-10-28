//
//  WatchStore.swift
//  OpenHikesWatch
//
//  Everything the watch keeps between launches: the hiker's list of trails,
//  the trail it was last handed, any finished walks the phone has not
//  confirmed yet, and the journal of a recording still in progress.
//
//  ## Why the watch stores anything at all
//
//  Because the link is the thing most likely to be missing exactly when this
//  app is being used. A phone in a rucksack twenty metres back down the path
//  is out of Bluetooth range; a phone that ran out of battery is out of range
//  for the rest of the walk. A watch that held the trail only in memory would
//  lose it to the first launch after the app was evicted, which on watchOS is
//  routine rather than exceptional.
//
//  ## The outbound queue is the important half
//
//  A recorded walk exists nowhere else. It is not in the hiker's library, not
//  in iCloud, not in Health — it is on this watch, and it stays here until the
//  phone says it has it. So it is written to disk the moment the recording
//  stops, before anything is sent, and removed only on a
//  ``WatchWalkReceipt``. That ordering is the whole design: a transfer that
//  fails, a watch that reboots mid-send and a phone that never comes back into
//  range all end in the same place, which is a walk still on disk and still
//  queued.
//
//  Each file is written with `.atomic`, which is what stops a process killed
//  mid-write from leaving a half-encoded walk that will never decode — the
//  same reason `SharedStore` uses it for every write it makes.
//
//  The queue itself is ``WatchWalkQueue``, an actor in the shared package: a
//  walk is a whole recording, so writing, reading and counting them happen
//  off the main actor, and counting reads only file names.
//

import Foundation
import OpenHikesShared
import os

/// The watch's own container, on the watch's own disk.
struct WatchStore: Sendable {
    nonisolated private static let logger = Logger(subsystem: "OpenHikesWatch", category: "Store")

    private let directory: URL
    /// Finished walks waiting for the phone — see ``WatchWalkQueue``.
    let walks: WatchWalkQueue

    /// - Parameter directory: where to keep everything. Injectable for the
    ///   same reason `SharedStore.containerOverride` is — a suite must never
    ///   write into the container a real install is using — even though this
    ///   target has no test bundle today. See the watch section of the
    ///   repository instructions for why it has none.
    init(directory: URL? = nil) {
        let resolved = directory ?? Self.defaultDirectory()
        self.directory = resolved
        walks = WatchWalkQueue(directory: resolved.appendingPathComponent("outbound", isDirectory: true))
    }

    private static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL.temporaryDirectory
        return base.appendingPathComponent("OpenHikesWatch", isDirectory: true)
    }

    private var digestURL: URL { directory.appendingPathComponent("library.json") }
    private var trailURL: URL { directory.appendingPathComponent("trail.json") }

    // MARK: The library

    /// The trails the phone last sent, or an empty digest — which is what a
    /// first launch, an unreadable file and a watch that has never been in
    /// range all look like, and all three draw the same empty state.
    func loadLibrary() -> WatchLibraryDigest {
        read(from: digestURL, WatchStoredFile.libraryDigest(from:)) ?? .empty
    }

    func save(_ digest: WatchLibraryDigest) {
        write(digest, to: digestURL)
    }

    // MARK: The trail

    /// The trail the watch was last handed, whichever one that was.
    ///
    /// One at a time, deliberately. A watch follows one trail, the phone sends
    /// the one that was asked for, and a cache of every trail a hiker ever
    /// opened would grow without anything to bound it — the argument
    /// `SharedStore.pruneTrailSnapshots(keeping:)` makes for the widget, where
    /// there is at least a set of placed widgets to bound it by. Here there is
    /// none.
    ///
    /// Which is also why there is no way to remove one: a trail is replaced
    /// wholesale by the next that arrives, and a watch holding one stale route
    /// costs a file rather than a decision.
    func loadTrail() -> WatchTrailPackage? {
        read(from: trailURL, WatchStoredFile.trailPackage(from:))
    }

    func save(_ package: WatchTrailPackage) {
        write(package, to: trailURL)
    }

    // MARK: The recording in progress

    /// Where a recording writes itself down as it goes, so a process that
    /// dies mid-walk leaves the walk behind — see ``WatchRecoveredRecording``.
    ///
    /// Beside the outbound queue rather than in it: a journal is not a walk
    /// the phone may be sent, and ``walks`` must never read one.
    var recordingJournal: WatchRecordingJournalFile {
        WatchRecordingJournalFile(url: directory.appendingPathComponent("recording.jsonl"))
    }

    // MARK: Files

    /// Through the same version check the link applies — see
    /// ``WatchStoredFile`` — so a file another build of this app wrote in
    /// another format reads as none, rather than reaching the screen.
    private func read<Value>(
        from url: URL,
        _ decode: (Data) throws(SharedPayloadReadFailure) -> Value
    ) -> Value? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do throws(SharedPayloadReadFailure) {
            return try decode(data)
        } catch {
            // Said rather than swallowed: a file that can never be decoded is
            // read again on every launch forever, and a cost that presents as
            // nothing at all is worth being able to see. The same argument
            // `SharedStoreDiagnostics` makes for the App Group.
            Self.logger.error(
                """
                \(url.lastPathComponent, privacy: .public) could not be read: \
                \(String(describing: error), privacy: .public)
                """
            )
            return nil
        }
    }

    @discardableResult private func write(_ value: some Encodable, to url: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try JSONEncoder().encode(value).write(to: url, options: .atomic)
            return true
        } catch {
            Self.logger.error(
                """
                \(url.lastPathComponent, privacy: .public) could not be written: \
                \(error.localizedDescription, privacy: .public)
                """
            )
            return false
        }
    }
}
