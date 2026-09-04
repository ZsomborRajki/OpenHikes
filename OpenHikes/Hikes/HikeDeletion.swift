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
