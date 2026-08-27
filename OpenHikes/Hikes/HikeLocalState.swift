//
//  HikeLocalState.swift
//  OpenHikes
//
//  The half of a hike that describes *this device's* disk, kept in its own
//  unmirrored store so CloudKit never sees it.
//
//  Everything here names files in this device's Application Support. Once the
//  app moved to SwiftData's own CloudKit mirroring, leaving these columns on
//  ``Hike`` stopped being a cosmetic problem and became a data-losing one:
//  mirroring syncs a whole row and resolves conflicts last-writer-wins, so a
//  second device's tile inventory would overwrite this one's. ``TileOwnership``
//  derives the tile claim set from exactly these two arrays, and
//  `TileCache.trimCache(claimedBy:)` deletes whatever no hike claims — so the
//  overwrite would strip this device of offline maps it really had downloaded,
//  at the next launch, with no way to notice.
//
//  A separate `@Model` in a second ``ModelConfiguration`` rather than a
//  relationship, because Core Data — and so SwiftData — forbids a relationship
//  that crosses two stores. The link is the hike's `id`, and ``Hike``'s
//  computed passthroughs are what keep that fact from leaking into the twenty
//  call sites that only ever wanted `hike.autoSavedTileKeys`.
//

import Foundation
import SwiftData

@Model
final class HikeLocalState {
    /// The hike this belongs to, and the only way back to it: a cross-store
    /// relationship is not available, so the join is done by value.
    ///
    /// Indexed because every access goes through it — see
    /// ``Hike/localState`` — and a table scan per tile-ownership question
    /// would land on the main actor.
    #Index<HikeLocalState>([\.hikeID])

    /// Defaulted for the same reason every column here is: this store is not
    /// mirrored, but it is still opened by SwiftData's lightweight migration,
    /// and a mandatory attribute with no default refuses to backfill.
    var hikeID = UUID()

    /// Records of offline tile downloads for this hike, enough to recompute
    /// (and so measure and remove) exactly the tiles each one saved.
    var offlineDownloads: [OfflineDownloadRecord] = []

    /// Cache keys of tiles auto-saved for this hike while browsing (OSM-style,
    /// non-bulk-downloadable providers) — recorded exactly, since (unlike
    /// ``OfflineDownloadRecord``) organic partial coverage can't be recomputed
    /// deterministically from a bounding box.
    var autoSavedTileKeys: [String] = []

    /// Whether auto-save is turned on for this hike's map.
    ///
    /// Device-local rather than a synced preference because it is a statement
    /// about whether *this* phone should be spending its storage and its
    /// connection on a map, which is not something the other one gets a vote
    /// on.
    var autoSaveTilesEnabled: Bool = true

    init(hikeID: UUID) {
        self.hikeID = hikeID
    }
}

// MARK: - Lookup

extension HikeLocalState {
    /// The row for `hikeID`, or `nil` when this device has never stored a tile
    /// for it.
    ///
    /// Deliberately does not create one. A read is a read: materialising a row
    /// because something asked whether a hike had offline maps would turn the
    /// hikes list into a writer, and a library of three hundred hikes into
    /// three hundred inserts on the first delete.
    static func existing(for hikeID: UUID, in context: ModelContext) -> HikeLocalState? {
        var descriptor = FetchDescriptor<HikeLocalState>(
            predicate: #Predicate { $0.hikeID == hikeID }
        )
        descriptor.fetchLimit = 1
        // `try?` because every caller is a property accessor with a meaningful
        // empty answer — no stored tiles — and the alternative is making
        // `hike.autoSavedTileKeys` throwing at twenty call sites to report a
        // failure none of them could act on.
        return (try? context.fetch(descriptor))?.first
    }

    /// The row for `hikeID`, created and inserted if this is the first time
    /// anything claimed a tile for it.
    static func forHike(_ hikeID: UUID, in context: ModelContext) -> HikeLocalState {
        if let existing = existing(for: hikeID, in: context) { return existing }
        let created = HikeLocalState(hikeID: hikeID)
        context.insert(created)
        return created
    }
}
