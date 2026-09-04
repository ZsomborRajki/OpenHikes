//
//  OfflineDownloadClaim.swift
//  OpenHikes
//
//  Recording which hike owns the tiles a bulk download just wrote, and
//  committing that record before anything reports the map as saved.
//
//  A downloaded map is two things in two places: bytes in Application
//  Support, and a record in the hike's ``HikeLocalState`` sidecar saying whose
//  they are. The bytes go first — there is nothing to claim until they are on
//  disk — so the window between them is the dangerous one:
//  `TileCache.trimCache(claimedBy:)` deletes every durable tile no hike
//  claims, so a run whose tiles landed and whose record did not has spent a
//  walker's connection, battery, time and storage on a map the next launch
//  quietly removes.
//
//  Which is why the claim is not a screen's job. It used to be:
//  `HikeDetailView` merged ``OfflineTileDownloader/completedRecord`` from an
//  `onChange`, so walking back to the list mid-download removed the only
//  observer that would ever have claimed the run — while the download itself
//  carried on writing tiles, because dismissing that view cancels nothing —
//  and the merge it did perform was left for whichever autosave happened to
//  pick it up. A download now claims its own coverage through here, from the
//  run's own task, and the phase the UI reads is published only once the
//  store has accepted it.
//

import Foundation
import os
import SwiftData

nonisolated enum OfflineDownloadClaim {
    private static let logger = Logger(
        subsystem: "OpenHikes",
        category: "OfflineDownload"
    )

    /// Why coverage that really reached disk could not be claimed. Both mean
    /// the same thing on disk — tiles nothing points at — and the same thing
    /// on screen: not "Saved for offline use."
    enum Failure: Equatable, Error, Sendable {
        /// The hike left the store while its tiles were being fetched. Its
        /// sidecar went with it, and a passthrough write to a detached
        /// ``Hike`` is a no-op rather than an error, so this is checked here
        /// rather than discovered by a manifest that stayed empty.
        case hikeIsGone
        /// The store refused the commit. The merge is rolled back with it, so
        /// the manifest still describes what the store really holds.
        case notSaved
    }

    /// Merges `record` into the hike's manifest and commits it.
    ///
    /// The rollback is what keeps a refusal honest: a merge left pending in
    /// the context is a claim the walker was told they don't have, waiting for
    /// whichever autosave lands next to make it true without a word. It also
    /// drops any other unsaved edit in the context, which is the price of not
    /// committing a claim that was refused — a context whose save has just
    /// failed has nothing that is going to be persisted anyway.
    ///
    /// - Parameter save: The seam the commit goes through, so a suite can
    ///   refuse one, the way ``HikeDeletion`` and ``HikeImport`` take theirs.
    @MainActor
    static func commit(
        _ record: OfflineDownloadRecord,
        for hike: Hike,
        save: (ModelContext) throws -> Void = { try $0.save() }
    ) throws(Failure) {
        guard hike.isAttached, let context = hike.modelContext else { throw .hikeIsGone }
        hike.mergeOfflineDownload(record)
        do {
            try save(context)
        } catch {
            context.rollback()
            logger.error(
                """
                Offline download coverage could not be committed for hike \
                \(hike.id, privacy: .public): \(error.localizedDescription, privacy: .public)
                """
            )
            throw .notSaved
        }
    }
}
