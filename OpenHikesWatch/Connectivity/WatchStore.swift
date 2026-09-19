//
//  WatchStore.swift
//  OpenHikesWatch
//
//  Everything the watch keeps between launches: the hiker's list of trails,
//  the trail it was last handed, and any finished walks the phone has not
//  confirmed yet.
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

import Foundation
import OpenHikesShared
import os

/// The watch's own container, on the watch's own disk.
struct WatchStore: Sendable {
    nonisolated private static let logger = Logger(subsystem: "OpenHikesWatch", category: "Store")

    private let directory: URL

    /// - Parameter directory: where to keep everything. Injectable for the
    ///   same reason `SharedStore.containerOverride` is — a suite must never
    ///   write into the container a real install is using — even though this
    ///   target has no test bundle today. See the watch section of the
    ///   repository instructions for why it has none.
    init(directory: URL? = nil) {
        self.directory = directory ?? Self.defaultDirectory()
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
    private var queueDirectory: URL {
        directory.appendingPathComponent("outbound", isDirectory: true)
    }

    // MARK: The library

    /// The trails the phone last sent, or an empty digest — which is what a
    /// first launch, an unreadable file and a watch that has never been in
    /// range all look like, and all three draw the same empty state.
    func loadLibrary() -> WatchLibraryDigest {
        read(WatchLibraryDigest.self, from: digestURL) ?? .empty
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
        read(WatchTrailPackage.self, from: trailURL)
    }

    func save(_ package: WatchTrailPackage) {
        write(package, to: trailURL)
    }

    // MARK: Walks waiting for the phone

    /// Every finished walk the phone has not confirmed, oldest first.
    ///
    /// Oldest first because that is the order they should be offered in: a
    /// hiker who has been out of range for two walks wants yesterday's in
    /// their library as much as today's, and a queue that sent the newest
    /// first would leave the older one behind whenever the link closed again
    /// mid-drain.
    func queuedWalks() -> [WatchRecordedWalk] {
        guard let names = try? FileManager.default.contentsOfDirectory(
            at: queueDirectory,
            includingPropertiesForKeys: nil
        ) else { return [] }
        return names
            .compactMap { read(WatchRecordedWalk.self, from: $0) }
            .sorted { $0.endedAt < $1.endedAt }
    }

    /// Puts a walk on the queue. Returns whether it is now on disk, because
    /// the caller has a walk in hand and nothing else to do with it: a walk
    /// that could not be written has to be said out loud rather than sent
    /// hopefully and forgotten.
    @discardableResult func enqueue(_ walk: WatchRecordedWalk) -> Bool {
        write(walk, to: walkURL(for: walk.sessionID))
    }

    /// Takes a walk off the queue, which only a receipt from the phone does.
    func removeWalk(_ sessionID: UUID) {
        try? FileManager.default.removeItem(at: walkURL(for: sessionID))
    }

    private func walkURL(for sessionID: UUID) -> URL {
        queueDirectory.appendingPathComponent("\(sessionID.uuidString).json")
    }

    // MARK: Files

    private func read<Value: Decodable>(_ type: Value.Type, from url: URL) -> Value? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            // Said rather than swallowed: a file that can never be decoded is
            // read again on every launch forever, and a cost that presents as
            // nothing at all is worth being able to see. The same argument
            // `SharedStoreDiagnostics` makes for the App Group.
            Self.logger.error(
                """
                \(url.lastPathComponent, privacy: .public) could not be read: \
                \(error.localizedDescription, privacy: .public)
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
