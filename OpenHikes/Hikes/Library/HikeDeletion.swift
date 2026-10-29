//
//  HikeDeletion.swift
//  OpenHikes
//
//  Taking a whole hike out of the store, in the one order that survives being
//  interrupted.
//
//  A hike is three things in three places — a row, a `HikeLocalState` sidecar
//  in the *other* store, and a pile of photo files nothing else points at —
//  and, for a hike that was recorded with the Health switch on, a fourth in a
//  store this app cannot read.
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
//  ## The workout in Health
//
//  ``HikeWorkoutWriting/write(_:)``'s own header states the invariant: Health
//  is a second store and it must never hold a walk this app does not. Deleting
//  a hike inverted it — the row, the sidecar, the photographs and the walk
//  history all went, and the `HKWorkout` and its `HKWorkoutRoute` stayed in
//  Health permanently, with the app having thrown away the only handle it had.
//
//  So ``HikeLocalState/healthWorkoutID`` is read *before* the sidecar goes —
//  a deleted row has nothing left to read — and spent *after* the store has
//  accepted the deletion, for the reason the photo files are: the identifier
//  is recoverable from the sidecar right up until the commit, and is gone
//  forever afterwards. A refused save therefore leaves the workout exactly
//  where it was, beside a hike that is still in the list.
//
//  It is the last thing to happen and the only one that cannot fail the
//  deletion. A hiker who asked for a hike to go gets it whether or not a
//  second store co-operates; the alternative is refusing to delete a hike
//  because HealthKit would not answer.
//
//  ## The walk from the watch
//
//  The watch keeps a walk until a receipt comes back, so a hike imported from
//  it can be offered again after it is gone, and the sidecar that recognised
//  the repeat — ``HikeLocalState/watchSessionID`` — goes with the hike. So the
//  identifier is read while the sidecar is still here, the way the workout's
//  is, and a ``DeletedWatchWalk`` is written in the *same* save as the
//  deletion: on disk exactly when the deletion is, and taken back with it by a
//  refusal. Without it, a retry made the deleted hike again.
//
//  Which is why every whole-hike deletion goes through here: the swipe in
//  `MapSheet`, the discarded recording draft, and the orphan sweep at launch.
//  All three used to erase the files first and hope the save that followed
//  landed.
//

import Algorithms
import Foundation
import OpenHikesData
import OpenHikesShared
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
    /// - Parameter workouts: Where a recorded hike's `HKWorkout` is removed
    ///   from, or `nil` for a launch with no Health writer — a hosted suite,
    ///   or a device with no Health store. `nil` is not a stub: the workout is
    ///   simply not deleted, exactly as it was not written.
    @MainActor
    static func delete(
        _ hike: Hike,
        among hikes: [Hike],
        autoSave: AutoSaveController,
        store: HikePhotoStore = .shared,
        workouts: (any HikeWorkoutWriting)? = nil,
        save: (ModelContext) throws -> Void = { try $0.save() }
    ) -> Outcome {
        let standDown = autoSave.standDown(for: hike)
        // And the same fold for whichever hike is auto-saving when it is not
        // this one — deleting a hike from the list while browsing another is
        // the ordinary way that happens. `standDown` covers only the doomed
        // hike, so without this the surviving hike's newest tiles are missing
        // from the claim set the plan is built from, and the plan frees them.
        // See ``StoredTileDeletion/delete(storedTilesOf:autoSave:downloads:fetchingHikes:save:)``.
        autoSave.flushPendingKeys()
        let plan = hike.hasStoredTiles
            ? StoredTileDeletionPlan(removing: hike, among: hikes)
            : nil
        do {
            try delete([hike], store: store, workouts: workouts, save: save)
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
    /// state it can safely leave on screen.
    ///
    /// Taken back through the context's rollback, because a deleted row cannot
    /// be put back by hand the way ``HikePlaceChange`` puts back a place. And
    /// so whatever the context already holds is committed first, in a save of
    /// its own, leaving the rollback nothing but the deletion to take. This is
    /// the shared main context, and it autosaves: a rename, or the tile claims
    /// auto-save folds in — the list's swipe folds the browsed hike's a moment
    /// before calling this — may be waiting there for the next save, and a
    /// refused deletion is no reason to lose them. A refusal is what a full
    /// disk does, and freeing space is the retry. A store that refuses that
    /// first commit has refused the deletion too, before anything was taken
    /// out.
    ///
    /// - Parameter hikes: All from one store. An empty list, or a hike that
    ///   was never inserted, needs no commit — nothing persisted it, so
    ///   nothing can bring it back and its files are free to go.
    /// - Parameter save: The seam both commits go through — what the context
    ///   already held, when it holds anything, and then the deletion — so a
    ///   test can watch what is on disk at the moment the deletion lands, or
    ///   refuse either one. The recorder passes its own — see
    ///   ``HikeRecorder/saveModelContext``.
    /// - Parameter workouts: Where a recorded hike's `HKWorkout` is removed
    ///   from — see this file's header. `nil` deletes no workout, which is
    ///   what a launch with no Health writer should do.
    @MainActor
    static func delete(
        _ hikes: [Hike],
        store: HikePhotoStore = .shared,
        workouts: (any HikeWorkoutWriting)? = nil,
        save: (ModelContext) throws -> Void = { try $0.save() }
    ) throws {
        guard !hikes.isEmpty else { return }
        let files = hikes.flatMap { $0.photos.map(HikePhotoStore.PhotoFiles.init) }
        // Read while the sidecar is still there, for the reason the file names
        // are read while the models are still attached: `deleteLocalState()`
        // takes the only record of this identifier with it, and after the
        // commit there is nothing left to ask. Spent after the save, so a
        // refusal leaves the workout beside the hike that is still in the
        // list. A workout Health is still writing has no identifier here yet;
        // ``HikeWorkoutExport/write(_:with:filingInto:)`` finds its hike gone
        // when Health answers, and takes that one back itself.
        let workoutIDs = hikes.compactMap { $0.localState?.healthWorkoutID }
        // The same, for the watch walks these hikes were imported from — see
        // this file's header.
        let watchSessionIDs = hikes.compactMap { $0.localState?.watchSessionID }
        // Read here for the reason the file names are: a deleted `@Model` has
        // nothing left to ask.
        let deletedIDs = hikes.map(\.id)
        let context = hikes.firstNonNil(\.modelContext)
        if let context, context.hasChanges {
            do {
                try save(context)
            } catch {
                logKept(error)
                throw error
            }
        }
        for hike in hikes {
            hike.deleteLocalState()
            hike.modelContext?.delete(hike)
        }
        if let context {
            for sessionID in watchSessionIDs {
                context.insert(DeletedWatchWalk(sessionID: sessionID))
            }
            do {
                try save(context)
            } catch {
                context.rollback()
                logKept(error)
                throw error
            }
        }
        HikePhotoImport.discardFiles(files, from: store)
        remove(workoutIDs, from: workouts)
        // The App Group copies of these trails, which nothing else would take.
        // A widget pinned to a deleted hike is *meant* to keep its snapshot
        // and its map through a mere deselection — see ``SharedStore/clear()``
        // — so the deletion has to be the thing that says otherwise, or the
        // route outlives the hike on somebody's Home Screen until the next
        // sweep.
        //
        // After the save, like the workouts and for the same reason: a refusal
        // leaves the snapshot beside the hike that is still in the list.
        for hikeID in deletedIDs {
            SharedStore.clearTrailSnapshot(for: hikeID)
            SharedStore.clearBasemaps(for: hikeID)
        }
    }

    private static func logKept(_ error: any Error) {
        logger.error(
            """
            Kept a hike whose deletion could not be saved: \
            \(error.localizedDescription, privacy: .public)
            """
        )
    }

    /// Takes the workouts out of Health, after the deletion is on disk.
    ///
    /// Fire-and-forget and logged, the shape ``HikeRecorder`` already uses for
    /// the write. Nothing waits on it and nothing reports it: the hike is gone
    /// from the list either way, and a hiker who has just deleted a walk has
    /// nothing to do about HealthKit declining to remove its copy. One task
    /// for the batch rather than one each, so the orphan sweep's dozen
    /// drafts — which carry no workout at all — cost nothing.
    @MainActor
    private static func remove(
        _ workoutIDs: [UUID],
        from workouts: (any HikeWorkoutWriting)?
    ) {
        guard let workouts, !workoutIDs.isEmpty else { return }
        Task {
            for workoutID in workoutIDs {
                do {
                    try await workouts.delete(workoutID: workoutID)
                } catch {
                    logger.error(
                        """
                        Health kept a workout whose hike was deleted: \
                        \(error.localizedDescription, privacy: .public)
                        """
                    )
                }
            }
        }
    }
}
