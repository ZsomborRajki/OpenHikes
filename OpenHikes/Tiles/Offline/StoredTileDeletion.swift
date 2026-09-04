//
//  StoredTileDeletion.swift
//  OpenHikes
//
//  Taking one hike's offline map off the device, in the one order that
//  survives being interrupted.
//
//  A saved map is two things in two places: tile files in Application
//  Support, and a manifest in the hike's ``HikeLocalState`` sidecar saying
//  they are its. The two cannot go in the same instant, so the only choice is
//  which way a refused save — or a process killed between them — falls, and
//  it is the choice ``HikeDeletion`` and ``OfflineDownloadClaim`` already
//  make: the manifest change is *saved* first, and the files go only once it
//  is on disk.
//
//  A kill in that window leaves durable tiles no hike claims, which
//  `TileCache.trimCache(claimedBy:)` reclaims at the next launch. Erasing
//  first leaves the other side of the same invariant, and it is the
//  unrecoverable one: the manifest comes back claiming files that are gone,
//  the hike goes on reporting a saved map, the storage row goes on counting
//  bytes that are not there — and because the claim still exists, every sweep
//  reads the state as intentional. Nothing re-downloads the map, and the
//  walker finds out where there is no signal.
//
//  Which is why the whole sequence is here rather than in `HikeDetailView`:
//  the screen owned it, wrote the manifests without ever saving them, and
//  started deleting files in the same breath.
//

import Foundation
import os
import SwiftData

nonisolated enum StoredTileDeletion {
    private static let logger = Logger(
        subsystem: "OpenHikes",
        category: "OfflineStorage"
    )

    /// Why a deletion did not happen, in the two shapes the walker meets it —
    /// both of which mean every tile is still on the device.
    enum Failure: Equatable, Sendable {
        /// A claim could not be read, so no plan could be built. Nothing was
        /// touched: the refusal happens before the first write.
        case claimsUnreadable
        /// The store refused the commit. The manifests, the tiles and
        /// auto-save are all back as they were.
        case notSaved
    }

    /// What the store did with the deletion, for the screen that asked.
    enum Outcome {
        /// On disk. The plan frees the tiles this hike claimed and no
        /// surviving hike still does — the caller spends it off the main
        /// thread, once it has taken the coverage off screen.
        case committed(freeing: StoredTileDeletionPlan)
        /// Refused, and nothing deleted. There is nothing for the caller to
        /// take off screen; the storage row still describes what is really
        /// there.
        case refused(Failure)
    }

    /// Forgets this hike's downloads and auto-saved tiles, commits that, and
    /// hands back the plan that frees their files.
    ///
    /// Every step is ordered against the commit:
    ///
    /// - Everything that can *refuse* is asked first, while nothing has been
    ///   written: the library fetch, this hike's own sidecar, and every
    ///   surviving hike's claim. A survivor missing from that set is not a
    ///   hike that claims nothing — it is a hike whose downloaded map is
    ///   about to be deleted while its manifest goes on listing it, which is
    ///   the same fail-closed rule the launch trim and Settings follow.
    /// - This hike's sidecar is resolved through the *throwing* spelling
    ///   before a single passthrough is touched. ``Hike/autoSavedTileKeys``
    ///   and its siblings read through ``Hike/localState``, which turns a
    ///   failed fetch into "this device has stored nothing", and writing
    ///   through that answer materialises a *second* sidecar row: the real
    ///   one is then unreachable behind a `fetchLimit` of one, still claiming
    ///   every tile this was asked to delete. Resolving here also warms the
    ///   cache the writes below read, so the two cannot disagree a line
    ///   apart.
    /// - Auto-save stands down *next*, and only then is the doomed claim
    ///   snapshotted. Switching it off folds the tiles saved since the last
    ///   drain into the manifest; a claim read ahead of that would be up to
    ///   two seconds stale, and everything saved since would be stranded on
    ///   durable storage with nothing left pointing at it.
    /// - The manifests are emptied, and the commit is the point of no return.
    ///   A refusal puts the whole thing back — manifests, the fold, the
    ///   preference and the arming — and deletes nothing.
    /// - Every download in flight is stood down once the commit lands, before
    ///   the plan is spent: their tiles are precisely the ones no hike claims
    ///   yet, so left running they would have them deleted and then claim
    ///   them back, putting the hike's coverage back moments after the walker
    ///   deleted it. Nothing can slip between the two — this holds the main
    ///   actor from the snapshot to here, and a claim is main-actor work.
    ///   Through ``OfflineDownloadRegistry`` rather than one screen's
    ///   downloader, because a run outlives the screen that started it: walk
    ///   back to the list and into the hike again and the view holds a fresh,
    ///   idle downloader while the real run is still writing tiles, invisible
    ///   to a stand-down aimed at the screen. A run for *another* hike
    ///   matters for the same reason from the other side — its tiles are
    ///   absent from the survivor snapshot, so this plan may free them, and
    ///   it would then claim files that are gone.
    ///
    /// - Parameter downloads: Where the runs still in flight are, so they can
    ///   be stood down — and only once the deletion is on disk. A refusal
    ///   leaves them alone: nothing was deleted, so there is nothing for them
    ///   to resurrect, and the walker never cancelled them.
    /// - Parameter fetch: The library, hikes and all, so the survivors' claims
    ///   can be read. A fetch that failed refuses the deletion rather than
    ///   shortening the set.
    /// - Parameter save: The seam the commit goes through, so a suite can
    ///   watch what is on disk at the moment the manifests land, or refuse
    ///   them — the way ``HikeDeletion`` and ``OfflineDownloadClaim`` take
    ///   theirs.
    @MainActor
    static func delete(
        storedTilesOf hike: Hike,
        autoSave: AutoSaveController,
        downloads: OfflineDownloadRegistry = .shared,
        fetchingHikes fetch: () throws -> [Hike],
        save: (ModelContext) throws -> Void = { try $0.save() }
    ) -> Outcome {
        // A hike that has left the store has no sidecar to empty and no
        // commit to make; a passthrough write to a detached `Hike` is a
        // silent no-op, so this is answered here rather than discovered by a
        // manifest that stayed full.
        guard hike.isAttached, let context = hike.modelContext else { return .refused(.notSaved) }

        let survivors: [TileOwnership]
        do {
            let hikes = try fetch()
            _ = try hike.resolveLocalState()
            survivors = try TileOwnership.claims(of: hikes.filter { $0.id != hike.id })
        } catch {
            logger.error(
                """
                Offline tiles were not deleted for hike \(hike.id, privacy: .public): \
                the device's tile claims could not be read.
                """
            )
            return .refused(.claimsUnreadable)
        }

        // Snapshotted before the fold, because that is what a refusal has to
        // put back: the manifest as the walker last saw it, with the
        // stand-down's own keys added on top by ``AutoSaveController``.
        let previousDownloads = hike.offlineDownloads
        let previousKeys = hike.autoSavedTileKeys
        let wasAutoSaving = hike.autoSaveTilesEnabled
        let standDown = autoSave.standDown(for: hike)
        // Recorded off as well as stood down: a hike whose saved map the
        // walker just deleted must not start saving it again on the next pan.
        autoSave.setEnabled(false, for: hike)
        let plan = StoredTileDeletionPlan(doomed: TileOwnership(hike), survivors: survivors)

        hike.offlineDownloads.removeAll()
        hike.autoSavedTileKeys.removeAll()
        do {
            try save(context)
        } catch {
            // Put back by hand rather than through `ModelContext.rollback()`,
            // which does not do it: measured here, a rolled-back context still
            // holds the emptied manifest and the switched-off preference — it
            // takes back an insertion or a deletion, not an attribute written
            // over an existing row. `AutoSaveController.sceneWillResignActive`
            // already restores this same property the same way, for the same
            // reason. And it has to be restored, because a manifest left empty
            // in the context is coverage the walker still has, waiting for
            // whichever autosave lands next to forget it without a word —
            // durable tiles the launch trim then reclaims, for a hike whose
            // deletion was refused.
            hike.offlineDownloads = previousDownloads
            hike.autoSavedTileKeys = previousKeys
            hike.autoSaveTilesEnabled = wasAutoSaving
            if let standDown {
                autoSave.restoreAfterRefusal(standDown, for: hike)
            }
            logger.error(
                """
                Offline tiles were not deleted for hike \(hike.id, privacy: .public): \
                \(error.localizedDescription, privacy: .public)
                """
            )
            return .refused(.notSaved)
        }

        downloads.standDown()
        return .committed(freeing: plan)
    }
}
