//
//  StoreLocation.swift
//  OpenHikes
//
//  Where the two SwiftData stores live on disk, and the one-time move that put
//  them there.
//
//  They used to live in the App Group container, and nobody chose that.
//  `ModelConfiguration` defaults `groupContainer` to `.automatic`, which means
//  "the first App Group in the entitlements", and the app has one — for the
//  widget's JSON snapshots, not for these stores. Nothing outside the app
//  opens them: the widget and the App Intents read ``SharedStore`` and
//  ``SharedHikeCatalogue``, never SwiftData.
//
//  The location is not cosmetic. RunningBoard kills a suspending app that
//  holds a file lock inside a *shared* container — `0xdead10cc` — because
//  another process could be left waiting on it. CloudKit mirroring imports
//  whenever a push wakes the app, and an import in progress holds a SQLite
//  lock, so a backgrounded app with a store in the group container could be
//  killed at any suspension that landed mid-import. The app's own container
//  has no such rule.
//
//  ## The move
//
//  Every file a store owns — the database, its `-wal` and `-shm`, and the
//  `.Name_SUPPORT` folder the `.externalStorage` routes are written to — has to
//  arrive together. A database opened without its write-ahead log loses the
//  transactions in it, and a stale log beside a database that moved on
//  corrupts it. So the files go into a staging folder first, one rename each,
//  and the staging folder becomes ``directory`` in one final rename. Until that
//  last step nothing opens either location, and a launch interrupted anywhere
//  before it finishes the same move the next time. Once ``directory`` exists
//  the move is over for good, and anything left in the group container is
//  never read again.
//

import Foundation
import OpenHikesShared

nonisolated enum StoreLocation {
    /// The configuration names, which SwiftData also uses as the file names.
    static let hikes = "Hikes"
    static let localState = "HikeLocalState"

    /// The app's own folder for both stores.
    static let directory = URL.applicationSupportDirectory
        .appending(path: "Stores", directoryHint: .isDirectory)

    /// Where `.automatic` put the stores: the group's own Application Support.
    static var legacyDirectory: URL? {
        SharedStore.appGroupContainerURL()?
            .appending(path: "Library/Application Support", directoryHint: .isDirectory)
    }

    static func storeURL(_ name: String, in directory: URL) -> URL {
        directory.appending(path: "\(name).store", directoryHint: .notDirectory)
    }

    /// Makes sure `directory` exists and holds the stores, moving them out of
    /// `legacyDirectory` the first time it runs, and returns it.
    ///
    /// A failed directory read or rename throws into the caller's temporary
    /// store fallback. Only a missing legacy directory means a fresh install;
    /// an unreadable one must leave the move unfinished so a later launch can
    /// retry, including when part of a store has already been staged.
    @discardableResult static func prepare(
        directory: URL = directory,
        legacyDirectory: URL? = legacyDirectory
    ) throws -> URL {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: directory.path(percentEncoded: false)) {
            return directory
        }
        let staging = directory.deletingLastPathComponent()
            .appending(path: "\(directory.lastPathComponent).moving", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)

        for item in try legacyItems(in: legacyDirectory) {
            let destination = staging.appending(path: item.lastPathComponent)
            // Already staged by a launch that stopped part-way.
            guard !fileManager.fileExists(atPath: destination.path(percentEncoded: false)) else {
                continue
            }
            try fileManager.moveItem(at: item, to: destination)
        }
        try fileManager.moveItem(at: staging, to: directory)
        return directory
    }

    /// Everything in `legacyDirectory` that belongs to one of the two stores.
    ///
    /// Matched by name rather than listed, so a sidecar SQLite or Core Data
    /// adds later still travels with its database.
    private static func legacyItems(in legacyDirectory: URL?) throws -> [URL] {
        guard let legacyDirectory else { return [] }
        let contents: [URL]
        do {
            contents = try FileManager.default.contentsOfDirectory(
                at: legacyDirectory,
                includingPropertiesForKeys: nil
            )
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return []
        }
        return contents.filter { item in
            let name = item.lastPathComponent
            return [hikes, localState].contains { store in
                name.hasPrefix("\(store).store") || name.hasPrefix(".\(store)_")
            }
        }
    }
}
