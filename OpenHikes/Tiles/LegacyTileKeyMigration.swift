//
//  LegacyTileKeyMigration.swift
//  OpenHikes
//
//  Retiring the tile keys written while display scale was still part of a
//  tile's identity.
//
//  ``TileCacheKey`` stopped spelling a scale into a key, which fixes every
//  tile saved from then on. It fixes nothing already on the device: a partial
//  download's `savedTileKeys` and a hike's `autoSavedTileKeys` are stored
//  verbatim, so both go on naming tiles as `…@2.0` or `…@3.0` after the
//  upgrade, and both are unioned into the claim set by ``TileOwnership``
//  exactly as written. Left alone that is the same bug the key change was
//  made to end, made permanent for the users who had actually downloaded
//  something: the launch sweep keeps their old files alive, the hike sheet
//  goes on reporting them as offline storage, and the renderer — asking only
//  for unsuffixed keys — refetches every one of them.
//
//  It also dead-ends auto-save. ``AutoSaveController`` seeds the store's
//  `knownKeys` from the manifest and ``AutoSaveTileStore`` caps that set at
//  3,000 keys, so a hike that reached the cap on the old format would reject
//  every new key it could actually use.
//
//  So the manifests are rewritten to the keys the renderer asks for, and the
//  files are renamed to match. The pass is idempotent by construction —
//  after it, no key carries a scale for it to strip — and runs at launch
//  before anything reads a manifest to decide what is claimed.
//

import Foundation
import os
import SwiftData

nonisolated enum LegacyTileKeyMigration {

    private static let logger = Logger(subsystem: "OpenHikes", category: "TileMigration")

    /// Rewrites this device's tile manifests, then renames the files they now
    /// name.
    ///
    /// That order is the safe one. Renaming first would leave every manifest
    /// claiming keys with nothing behind them if the save then failed, and a
    /// claim set is what stops ``TileCache/trimCache(claimedBy:limit:)``
    /// deleting a downloaded map — so the window between the two steps has to
    /// be one where the files are still where the manifests say they are.
    @MainActor
    static func run(in context: ModelContext, cache: TileCache = .shared) {
        run(
            cache: cache,
            fetchingLocalStates: { try context.fetch(FetchDescriptor<HikeLocalState>()) },
            saving: { try context.save() }
        )
    }

    /// The rule itself, with the store reads handed in — the same seam
    /// ``OpenHikesModel/trimTileCache(_:limit:fetchingHikes:)`` uses, and for
    /// the same reason: a fetch that failed must migrate nothing, and nothing
    /// makes a `ModelContext` throw on demand.
    ///
    /// The rename goes through ``TileCache/scheduleMaintenance(_:)``, which is
    /// one serial queue — so a trim scheduled after this call is already
    /// guaranteed to see the renamed files rather than race them.
    @MainActor
    static func run(
        cache: TileCache,
        fetchingLocalStates fetch: () throws -> [HikeLocalState],
        saving save: () throws -> Void
    ) {
        let moves = rewriteManifests(fetchingLocalStates: fetch, saving: save)
        guard !moves.isEmpty else { return }
        TileCache.scheduleMaintenance { cache.renameTiles(moves) }
    }

    /// Points every manifest on this device at the keys the renderer asks for,
    /// and reports the renames that leaves the files needing: legacy key to
    /// current key.
    ///
    /// A save that fails puts every row back as it was and reports no moves.
    /// The alternative is a device whose files have been renamed and whose
    /// manifests still name the old ones — offline coverage that nothing
    /// claims, which the next sweep is entitled to delete.
    @MainActor
    static func rewriteManifests(
        fetchingLocalStates fetch: () throws -> [HikeLocalState],
        saving save: () throws -> Void
    ) -> [String: String] {
        guard let rows = try? fetch() else { return [:] }

        var moves: [String: String] = [:]
        var rollback: [(row: HikeLocalState, keys: [String], downloads: [OfflineDownloadRecord])] = []
        for row in rows {
            let keys = migrated(keys: row.autoSavedTileKeys)
            let downloads = migrated(downloads: row.offlineDownloads)
            guard keys != row.autoSavedTileKeys || downloads != row.offlineDownloads else { continue }
            collectMoves(from: row.autoSavedTileKeys, into: &moves)
            for download in row.offlineDownloads {
                collectMoves(from: download.savedTileKeys, into: &moves)
            }
            rollback.append((row, row.autoSavedTileKeys, row.offlineDownloads))
            row.autoSavedTileKeys = keys
            row.offlineDownloads = downloads
        }
        guard !rollback.isEmpty else { return [:] }

        do {
            try save()
        } catch {
            for entry in rollback {
                entry.row.autoSavedTileKeys = entry.keys
                entry.row.offlineDownloads = entry.downloads
            }
            logger.error(
                // swiftlint:disable:next line_length
                "Could not migrate legacy tile manifests: \(error.localizedDescription, privacy: .public)"
            )
            return [:]
        }
        return moves
    }

    /// The keys `keys` names now: each rewritten, duplicates collapsed, order
    /// kept.
    ///
    /// Collapsing matters as much as rewriting for ``autoSavedTileKeys``. A
    /// device that browsed one tile at two scales holds two keys for it, which
    /// become one key twice — and that set is both the dedupe set and what the
    /// 3,000-key cap is counted against, so leaving the duplicate would spend
    /// a slot on a tile the hike already has.
    static func migrated(keys: [String]) -> [String] {
        var seen = Set<String>()
        var migrated: [String] = []
        migrated.reserveCapacity(keys.count)
        for key in keys {
            let current = TileCacheKey.withoutDisplayScale(key)
            guard seen.insert(current).inserted else { continue }
            migrated.append(current)
        }
        return migrated
    }

    /// The download records `downloads` amounts to now.
    ///
    /// Two things happen here. Each record's exact keys are rewritten, and
    /// records that differed only by the scale they were taken at are folded
    /// together — the same rule ``Hike/mergeOfflineDownload(_:)`` applies to a
    /// re-download, applied to what is already stored, since after the key
    /// change a provider and a depth is all a record is. `scale` goes back to
    /// the zero a record written today carries: nothing reads it, and leaving
    /// the old value there is the only thing that would still say this record
    /// predates the change.
    static func migrated(downloads: [OfflineDownloadRecord]) -> [OfflineDownloadRecord] {
        var folded: [OfflineDownloadRecord] = []
        for download in downloads {
            let record = OfflineDownloadRecord(
                providerID: download.providerID,
                maxZoom: download.maxZoom,
                savedTileKeys: migrated(keys: download.savedTileKeys).sorted()
            )
            guard let index = folded.firstIndex(where: { existing in
                existing.providerID == record.providerID && existing.maxZoom == record.maxZoom
            }) else {
                folded.append(record)
                continue
            }
            folded[index] = folding(folded[index], with: record)
        }
        return folded
    }

    /// Two records for one provider and depth, as one.
    ///
    /// An empty `savedTileKeys` means the whole deterministic grid was saved,
    /// so it absorbs any partial record beside it rather than being narrowed
    /// to that record's exact keys.
    private static func folding(
        _ existing: OfflineDownloadRecord,
        with record: OfflineDownloadRecord
    ) -> OfflineDownloadRecord {
        guard !existing.savedTileKeys.isEmpty, !record.savedTileKeys.isEmpty else {
            return OfflineDownloadRecord(providerID: existing.providerID, maxZoom: existing.maxZoom)
        }
        return OfflineDownloadRecord(
            providerID: existing.providerID,
            maxZoom: existing.maxZoom,
            savedTileKeys: Set(existing.savedTileKeys).union(record.savedTileKeys).sorted()
        )
    }

    private static func collectMoves(from keys: [String], into moves: inout [String: String]) {
        for key in keys {
            let current = TileCacheKey.withoutDisplayScale(key)
            guard current != key else { continue }
            moves[key] = current
        }
    }
}
