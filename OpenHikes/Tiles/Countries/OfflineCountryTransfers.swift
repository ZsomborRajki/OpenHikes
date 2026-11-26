//
//  OfflineCountryTransfers.swift
//  OpenHikes
//
//  Which session task a country file's callbacks are taken from (#1659).
//  Cancelling an area and downloading it again asks for the same files of
//  the same build under the same key, and the cancelled task can still
//  report, finish or end after its replacement has begun, or after the
//  replacement has ended. Its callbacks touch nothing of the replacement's:
//  no staging, no progress, no completion bookkeeping and no event.
//
//  A file's owner is the task this launch last started for it, and it stays
//  the owner once it has ended, so a task it replaced is still told apart
//  from it. A file this launch has started nothing for is an earlier
//  launch's, whose tasks are taken as they come, unless a cancel has ended
//  its area since: then nothing of that area is taken until a task is
//  started for it again. A background session gives a new task an
//  identifier none of its tasks has, an earlier launch's included, even
//  one that finished while the app was away and has yet to say so (watched
//  on an iOS 27.2 simulator and on macOS), so an earlier launch's task is
//  never taken for this launch's.
//
//  A value, so the session's callbacks decide and record under one lock
//  (``BackgroundCountryDownloader``), and a suite holds the rules without a
//  session.
//

import Foundation

nonisolated struct OfflineCountryTransfers: Sendable {
    /// What a task's end says to the model.
    enum Ending: Equatable, Sendable {
        /// It is not its file's transfer, and says nothing.
        case refused
        /// Its file landed, which the landing said already.
        case landed
        /// It stopped short.
        case stopped
    }

    /// The task this launch last started for each file.
    private var owners: [OfflineCountryDownloadKey: Int] = [:]
    /// The areas a cancel ended in this launch.
    private var cancelled: Set<String> = []
    /// Where each owner's file goes.
    private var staging: [OfflineCountryDownloadKey: URL] = [:]
    private var lastProgress: [OfflineCountryDownloadKey: ContinuousClock.Instant] = [:]
    /// The files whose transfer landed and has yet to end.
    private var landed: Set<OfflineCountryDownloadKey> = []

    /// Whether `transfer`'s callbacks are its file's.
    func takes(_ transfer: OfflineCountryTransfer) -> Bool {
        if let owner = owners[transfer.key] { return owner == transfer.task }
        return !cancelled.contains(transfer.key.country)
    }

    /// `transfer` is starting, with its file to be staged at `url`, and
    /// whichever task its file had before is no longer taken.
    mutating func start(_ transfer: OfflineCountryTransfer, stagingAt url: URL) {
        let key = transfer.key
        owners[key] = transfer.task
        staging[key] = url
        lastProgress[key] = nil
        landed.remove(key)
    }

    /// The area `country` was cancelled: no task of it is taken, an earlier
    /// launch's included, until one is started for a file of it again.
    mutating func cancel(country: String) {
        cancelled.insert(country)
        for key in Set(owners.keys).union(staging.keys) where key.country == country {
            owners[key] = nil
            staging[key] = nil
            lastProgress[key] = nil
            landed.remove(key)
        }
    }

    /// Whether progress `transfer` reports `now` is passed on: it is its
    /// file's, and the last was passed on at least `interval` ago.
    mutating func reports(
        _ transfer: OfflineCountryTransfer,
        at now: ContinuousClock.Instant,
        every interval: Duration
    ) -> Bool {
        guard takes(transfer) else { return false }
        if let last = lastProgress[transfer.key], now - last < interval { return false }
        lastProgress[transfer.key] = now
        return true
    }

    /// Stages `transfer`'s file through `move`, when it is its file's, and
    /// answers where: where its start said, or `fallback` for a task an
    /// earlier launch started, since a relaunch forgets what was staged
    /// where. `nil`, and nothing moved, for any other task.
    mutating func land(
        _ transfer: OfflineCountryTransfer,
        fallback: URL,
        by move: (URL) throws -> Void
    ) rethrows -> URL? {
        guard takes(transfer) else { return nil }
        let staged = staging[transfer.key] ?? fallback
        try move(staged)
        landed.insert(transfer.key)
        return staged
    }

    /// `transfer` ended. Its file keeps it as its owner, so a task it
    /// replaced is still refused after it.
    mutating func end(_ transfer: OfflineCountryTransfer) -> Ending {
        guard takes(transfer) else { return .refused }
        let key = transfer.key
        staging[key] = nil
        lastProgress[key] = nil
        return landed.remove(key) != nil ? .landed : .stopped
    }
}
