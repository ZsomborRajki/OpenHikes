//
//  TileCache+TierDuplicates.swift
//  OpenHikes
//
//  One file per key, and which of the two tiers is allowed to hold it.
//
//  ``TileCache/filePaths(forKey:)`` states the invariant: a tile lives in the
//  browsing tier or the durable one, never both. The write paths keep it, and
//  these two are what they keep it with — plus what heals an install that
//  already has duplicates, from a build whose write paths did not.
//
//  Durable normally wins, because the only question a duplicate of identical
//  bytes raises is which copy the OS may reclaim, and a hike is counting on the
//  answer being "not that one". The exception is age. Durable coverage is no
//  longer deleted for being stale — see
//  ``TileCache/loadTileResult(forKey:url:purpose:)`` — so "durable wins" over a
//  duplicate can now mean deleting the only fresh tile on the device and
//  keeping the week-old one. Where the browsing copy is the newer of the two,
//  it is promoted rather than discarded.
//

import Foundation
import os

nonisolated extension TileCache {

    /// Replaces durable coverage with a *newer* browsing-tier copy of the same
    /// key, instead of discarding the newer bytes.
    ///
    /// ``discardRedundantCachedCopy(forKey:)`` is the ordinary answer to a key
    /// held in both tiers, and it is the right one whenever the two hold the
    /// same bytes — which is all the current write paths can produce. A
    /// duplicate left behind by an older build is the exception, and it becomes
    /// visible only once the durable side is past the TTL: "durable wins" then
    /// deletes the one fresh tile on the device and keeps the week-old one, and
    /// the walker is shown old ground until a refresh they may have no signal
    /// to make. Newer wins there.
    ///
    /// Returns whether the browsing copy was adopted. `false` — including when
    /// either date cannot be read, since an unknown age is not evidence of a
    /// newer file — leaves both files exactly as they were, for the caller to
    /// resolve its own way.
    ///
    /// Call with ``mutationVersions`` held.
    func adoptNewerCachedCopy(cached: URL, durable: URL, diskName name: String) -> Bool {
        guard let cachedAt = modificationDate(of: cached),
              let durableAt = modificationDate(of: durable),
              cachedAt > durableAt
        else { return false }

        let previousBytes = fileSize(durable)
        let adoptedBytes = fileSize(cached)
        do {
            // Written atomically over the destination rather than moved onto
            // it. These are bytes a hike is claiming, and nothing on this path
            // may leave the saved copy absent — not even for the width of a
            // rename that can fail with the destination already cleared.
            try Data(contentsOf: cached).write(to: durable, options: .atomic)
        } catch {
            logFileError(error, operation: "adopt newer cached tile", url: cached)
            return false
        }
        // That write stamps the file with *now*, and the TTL reads a tile's
        // modification date as when its bytes were fetched. They were fetched
        // when the copy they came from was, so the date travels with them. A
        // failure here only makes the tile look fresher than it is, which the
        // refresh it eventually asks for corrects.
        try? FileManager.default.setAttributes(
            [.modificationDate: cachedAt],
            ofItemAtPath: durable.path
        )
        _ = removeItemIgnoringNotFound(
            at: cached,
            operation: "remove adopted cached tile"
        )
        adjustDurableBytes(
            forProviderID: Self.providerID(forDiskName: name),
            by: adoptedBytes - previousBytes
        )
        return true
    }

    /// Enforces the one-file-per-key rule in the one direction it can go wrong:
    /// a browsing-tier copy of a tile that is also stored durably.
    ///
    /// Durable wins because it's the stronger claim — the bytes are identical,
    /// so the only question is which file is allowed to be reclaimed by the OS,
    /// and a hike is counting on the answer being "not this one". Called after
    /// every write, since the map's write and a download's write are ordered
    /// only by chance.
    ///
    /// "Identical" is what makes that safe, and it is what the write paths
    /// guarantee. Callers reconciling a duplicate they did not write —
    /// ``promoteCachedTile(forKey:racingWriter:)`` and the launch sweep — go
    /// through ``adoptNewerCachedCopy(cached:durable:diskName:)`` first, which
    /// is where a browsing copy that is genuinely newer is kept instead.
    func discardRedundantCachedCopy(forKey key: String) {
        let (cached, durable) = filePaths(forKey: key)
        guard FileManager.default.fileExists(atPath: durable.path) else { return }
        _ = removeItemIgnoringNotFound(
            at: cached,
            operation: "remove redundant cached tile"
        )
    }

}
