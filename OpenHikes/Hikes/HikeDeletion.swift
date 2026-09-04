//
//  HikeDeletion.swift
//  OpenHikes
//
//  Taking a whole hike out of the store, in the one order that survives being
//  interrupted.
//
//  A hike is three things in three places: a row, a `HikeLocalState` sidecar
//  in the *other* store, and a pile of photo files nothing else points at.
//  The row and the files cannot go in the same instant, so the only choice is
//  which way a process killed between them falls — the same choice
//  ``HikePhotoImport/remove(_:from:store:save:)`` makes for a single photo,
//  and it is made the same way here: the deletion is *saved* first, and the
//  pixels go only once it is on disk.
//
//  A kill in that window leaves files no `Hike` claims, which
//  ``OpenHikesModel/reclaimOrphanedPhotos(in:store:)`` sweeps at the next
//  launch. Erasing first would leave the hike back in the list — its gallery
//  pointing at pixels no sweep can bring back, which is the unrecoverable
//  side of the same invariant.
//
//  Which is why every whole-hike deletion goes through here: the swipe in
//  `MapSheet`, the discarded recording draft, and the orphan sweep at launch.
//  All three used to erase the files first and hope the save that followed
//  landed.
//

import Foundation
import os
import SwiftData

nonisolated enum HikeDeletion {
    private static let logger = Logger(
        subsystem: "OpenHikes",
        category: "HikeDeletion"
    )

    /// What the store did with a deletion, for the screen that asked for it.
    enum Outcome {
        /// On disk. The plan, when there is one, frees the tiles this hike had
        /// saved offline and no surviving hike still claims — the caller
        /// spends it off the main thread.
        case committed(freeing: StoredTileDeletionPlan?)
        /// Refused, and everything put back: the hike, its sidecar, its files,
        /// and auto-save. There is nothing for the caller to take off screen.
        case refused
    }

    /// Deletes one hike out of the list, with everything that has to happen
    /// around it in the order it has to happen in.
    ///
    /// Extracted from `MapSheet.delete(_:among:)`, the way
    /// ``SheetRoute/removeHike(_:selectedHike:from:)`` was, so a test can call
    /// the sequence rather than restate it — and this is a sequence where
    /// every step is ordered against the commit:
    ///
    /// - Auto-save stands down *first*. Tiles saved in the last drain window
    ///   live only in ``AutoSaveTileStore``'s pending set; folding them into
    ///   the manifest now is what stops them outliving the hike with nothing
    ///   pointing at them, and it closes the window where a tile still in
    ///   flight lands on disk claimed by a hike that no longer exists.
    /// - The tile plan is built *second*, because it reads the manifest that
    ///   fold just completed, and because the sidecar it reads goes with the
    ///   hike. It is spent last, by the caller, once the deletion is on disk.
    /// - A plan that cannot be built frees nothing, the way the launch trim
    ///   and Settings refuse theirs: a survivor whose sidecar read failed is
    ///   missing from the claim set, and spending a set that is short by one
    ///   hike is how a neighbour loses the map it downloaded for a valley with
    ///   no signal. The hike is still deleted either way; its own tiles are
    ///   then unclaimed, and the next launch trim reclaims them.
    ///
    /// A refused save puts all of it back, auto-save included, and says so —
    /// so the caller can leave the screen exactly as the user left it.
    @MainActor
    static func delete(
        _ hike: Hike,
        among hikes: [Hike],
        autoSave: AutoSaveController,
        store: HikePhotoStore = .shared,
        save: (ModelContext) throws -> Void = { try $0.save() }
    ) -> Outcome {
        let standDown = autoSave.standDown(for: hike)
        let plan = hike.hasStoredTiles
            ? StoredTileDeletionPlan(removing: hike, among: hikes)
            : nil
        do {
            try delete([hike], store: store, save: save)
        } catch {
            if let standDown {
                autoSave.restoreAfterRefusal(standDown, for: hike)
            }
            return .refused
        }
        return .committed(freeing: plan)
    }

    /// Deletes these hikes, their sidecars and their photo files, in that
    /// order, and reports a commit that was refused.
    ///
    /// The file names are snapshotted while the models are still attached — a
    /// deleted `@Model` has nothing left to enumerate — and are spent only
    /// after the store has accepted the deletion.
    ///
    /// The sidecar goes before the row for a reason of its own:
    /// ``Hike/deleteLocalState()`` reaches it through the hike's own
    /// `modelContext`, and a deleted row has none. Nothing cascades between
    /// the two stores, and nothing ever fetches a ``HikeLocalState`` except by
    /// the id of a hike that still exists, so one left behind is unreachable
    /// and unsweepable — and goes on claiming this hike's tiles forever.
    ///
    /// A refused save takes the whole deletion back rather than leaving half
    /// of it pending: the caller is left with hikes that are still in the
    /// store, sidecars that still exist, and every file still on disk — the
    /// state it can safely leave on screen. The rollback also drops any other
    /// unsaved edit in the context, which is the price of not committing a
    /// deletion the user did not get: a context whose save has just failed has
    /// nothing that is going to be persisted anyway.
    ///
    /// - Parameter hikes: All from one store. An empty list, or a hike that
    ///   was never inserted, needs no commit — nothing persisted it, so
    ///   nothing can bring it back and its files are free to go.
    /// - Parameter save: The seam the commit goes through, so a test can watch
    ///   what is on disk at the moment the deletion lands, or refuse it. The
    ///   recorder passes its own — see ``HikeRecorder/saveModelContext``.
    @MainActor
    static func delete(
        _ hikes: [Hike],
        store: HikePhotoStore = .shared,
        save: (ModelContext) throws -> Void = { try $0.save() }
    ) throws {
        guard !hikes.isEmpty else { return }
        let files = hikes.flatMap { $0.photos.map(HikePhotoStore.PhotoFiles.init) }
        let context = hikes.compactMap(\.modelContext).first
        for hike in hikes {
            hike.deleteLocalState()
            hike.modelContext?.delete(hike)
        }
        if let context {
            do {
                try save(context)
            } catch {
                context.rollback()
                logger.error(
                    """
                    Kept a hike whose deletion could not be saved: \
                    \(error.localizedDescription, privacy: .public)
                    """
                )
                throw error
            }
        }
        HikePhotoImport.discardFiles(files, from: store)
    }
}
