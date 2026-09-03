//
//  TileCache+LegacyKeys.swift
//  OpenHikes
//
//  Moving tiles saved under a pre-change key to the name the renderer now
//  looks them up by. See ``LegacyTileKeyMigration``.
//

import Foundation
import Synchronization

nonisolated extension TileCache {

    /// Renames stored tiles, `moves` mapping a key written by an older build
    /// to the key it names today.
    ///
    /// A rename rather than a delete because the bytes are a walker's saved
    /// map: the file holds exactly the tile the renderer is about to ask for,
    /// under a name it will never ask for again. Dropping it instead would
    /// leave a hike whose sheet said "saved" re-fetching every tile of it —
    /// which is the bug this migration exists to end, not to reproduce for
    /// everyone who had already downloaded something.
    ///
    /// Both tiers, because a download populates the browsing cache too and
    /// ``diskUsage(claimedBy:)`` counts a claimed tile wherever it landed.
    func renameTiles(_ moves: [String: String]) {
        assertOffMainThread(
            "renameTiles(_:) moves tile files synchronously — call it off the main thread"
        )
        guard !moves.isEmpty else { return }
        let interval = RenderSignpost.beginInterval("TileLegacyKeyMigration")
        var renamed = 0
        defer {
            RenderSignpost.mark("TileLegacyKeysMigrated", "keys=\(moves.count) renamed=\(renamed)")
            RenderSignpost.endInterval("TileLegacyKeyMigration", interval)
        }
        for (legacy, current) in moves where legacy != current {
            let source = filePaths(forKey: legacy)
            let destination = filePaths(forKey: current)
            // Per key rather than the epoch, and for the reason `trimCache`
            // gives: the tile leaving `legacy` is one tile, and invalidating
            // every in-flight fetch once per renamed tile would discard a
            // download's worth of correct responses.
            mutationVersions.withLock { versions in
                versions.invalidate(diskName(for: legacy))
                // swiftlint:disable:next legacy_objc_type
                memory.removeObject(forKey: legacy as NSString)
                if moveTile(from: source.durable, to: destination.durable) { renamed += 1 }
                if moveTile(from: source.cached, to: destination.cached) { renamed += 1 }
            }
        }
        invalidateDurableMeasurements()
    }

    /// Moves one tile file, or drops it when the destination is already
    /// occupied.
    ///
    /// Two legacy keys can name one tile — a device that downloaded at `@3.0`
    /// and browsed at `@2.0` holds both — and only one of them can become the
    /// key they now share. Whatever is already stored under that key wins:
    /// it is what the renderer has been reading, and the loser is a duplicate
    /// of the same bytes from the same URL.
    private func moveTile(from source: URL, to destination: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: source.path) else { return false }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            return removeItemIgnoringNotFound(
                at: source,
                operation: "remove superseded legacy tile"
            )
        }
        do {
            try FileManager.default.moveItem(at: source, to: destination)
            return true
        } catch {
            logFileError(error, operation: "rename legacy tile", url: source)
            return false
        }
    }
}
