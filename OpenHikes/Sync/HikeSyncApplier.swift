//
//  HikeSyncApplier.swift
//  OpenHikes
//
//  The SwiftData half of sync: everything that has to happen on the main actor
//  because a `@Model` lives there, and nothing that doesn't.
//
//  Kept apart from ``HikeSyncEngine`` — which is an `actor`, because
//  `CKSyncEngineDelegate` requires a `Sendable` delegate — so that the
//  isolation boundary is a type boundary rather than a scattering of
//  `MainActor.run` blocks. What crosses it is `Sendable` payloads and record
//  names, never a model object.
//

import CloudKit
import Foundation
import os
import SwiftData

/// One record's worth of local data, snapshotted on the main actor so the
/// expensive part — compressing a route, handing CloudKit a file — can happen
/// off it.
nonisolated enum PendingUpload: Sendable {
    case hike(HikeSyncPayload)
    case photo(HikePhotoSyncPayload, imageURL: URL)
}

/// What this device holds that iCloud ought to know about.
nonisolated struct SyncableIdentifiers: Equatable, Sendable {
    var hikeIDs: [UUID] = []
    var photoIDs: [UUID] = []

    var isEmpty: Bool { hikeIDs.isEmpty && photoIDs.isEmpty }
}

@MainActor
final class HikeSyncApplier {
    private static let logger = Logger(subsystem: "OpenHikes", category: "CloudSync")

    /// True while a change fetched from iCloud is being written.
    ///
    /// Read by ``CloudSyncCoordinator``'s save observer, which would otherwise
    /// see the write this makes, conclude the user had edited something, and
    /// queue it straight back for upload — a loop that would keep two devices
    /// talking to each other forever over a hike neither of them changed.
    private(set) var isApplyingRemoteChanges = false

    private let container: ModelContainer
    private let photoStore: HikePhotoStore

    init(container: ModelContainer, photoStore: HikePhotoStore = .shared) {
        self.container = container
        self.photoStore = photoStore
    }

    private var context: ModelContext { container.mainContext }

    // MARK: - Reading

    /// Every hike worth uploading and every photo attached to one.
    ///
    /// Used to seed a first sync and to reconcile afterwards: anything in here
    /// with no acknowledged server record has never made it up, whether
    /// because sync was off when it was recorded or because the send was
    /// interrupted.
    func syncableIdentifiers() -> SyncableIdentifiers {
        guard let hikes = try? context.fetch(FetchDescriptor<Hike>()) else {
            // An empty result, which makes ``HikeSyncEngine/reconcile()``
            // upload nothing this launch rather than act on a half-read
            // store. Safe only because it is used in one direction: the
            // deletion half of reconciliation asks ``allHikeIDs()``, which
            // throws instead, precisely because an under-reported set *there*
            // would delete real hikes out of iCloud. A missed upload costs a
            // launch; a missed hike costs the hike.
            return SyncableIdentifiers()
        }
        var identifiers = SyncableIdentifiers()
        for hike in hikes where !hike.isRecording {
            identifiers.hikeIDs.append(hike.id)
            identifiers.photoIDs.append(contentsOf: hike.photos.map(\.id))
        }
        return identifiers
    }

    /// Snapshots the records named by `recordNames`.
    ///
    /// One fetch for the whole batch rather than one per record: the batch is
    /// up to 250 records, and a hike's photos are reached through the hike.
    /// A name with nothing behind it is simply absent from the result, which
    /// is how ``CKSyncEngine`` is told to drop that change.
    /// - Throws: Whatever the fetch threw. Deliberately not answered with an
    ///   empty result: the caller reads an absent name as "deleted locally"
    ///   and drops the pending change, so one transient failure would discard
    ///   every queued save in the batch — and an edit to an already-synced
    ///   hike is not recoverable by reconciling, because it has a server
    ///   record and so nothing asks about it again.
    func uploads(for recordNames: Set<String>) throws -> [String: PendingUpload] {
        let ids = Set(recordNames.compactMap(UUID.init(uuidString:)))
        guard !ids.isEmpty else { return [:] }
        let hikes = try context.fetch(FetchDescriptor<Hike>())

        var uploads: [String: PendingUpload] = [:]
        for hike in hikes {
            if ids.contains(hike.id), let payload = HikeSyncPayload(hike: hike) {
                uploads[hike.id.uuidString] = .hike(payload)
            }
            guard !hike.isRecording else { continue }
            for photo in hike.photos where ids.contains(photo.id) {
                uploads[photo.id.uuidString] = .photo(
                    HikePhotoSyncPayload(hikeID: hike.id, photo: photo),
                    imageURL: photoStore.url(for: photo)
                )
            }
        }
        return uploads
    }

    // MARK: - Writing

    /// Runs `work` with the save observer muted, then commits.
    ///
    /// The explicit save matters as much as the flag: SwiftData's autosave
    /// would otherwise write these changes *after* the flag came down, and the
    /// observer would see them as the user's own edits.
    private func applyingRemoteChanges<Value>(_ work: () throws -> Value) throws -> Value {
        // Anything the user changed that SwiftData hasn't autosaved yet is
        // committed first, with the flag *down*, so the observer sees it as
        // the local edit it is. Almost every edit in this app is autosave-only
        // — a renamed hike, a re-tinted route, a changed line width — so
        // there is always a window between the tap and the write. Folding one
        // into the flagged save below would have the observer discard it, and
        // a saved model is clean, so nothing would ever mention it again:
        // silently local forever.
        //
        // A flush that throws aborts before anything remote is applied. The
        // rollback below is unscoped — it would take the user's uncommitted
        // edit with it — so the only safe rule is that it can never run while
        // there is local work still in the context.
        try flushLocalEdits()

        isApplyingRemoteChanges = true
        defer { isApplyingRemoteChanges = false }
        do {
            let value = try work()
            try context.save()
            return value
        } catch {
            Self.logger.error(
                """
                Could not apply changes fetched from iCloud: \
                \(error.localizedDescription, privacy: .public)
                """
            )
            // Rolled back rather than left dirty: these mutations would
            // otherwise be committed by the next autosave, with the flag down,
            // and be uploaded straight back as though the user had made them.
            context.rollback()
            throw error
        }
    }

    private func flushLocalEdits() throws {
        guard context.hasChanges else { return }
        do {
            try context.save()
        } catch {
            Self.logger.error(
                """
                Could not commit local edits before applying iCloud changes: \
                \(error.localizedDescription, privacy: .public)
                """
            )
            throw error
        }
    }

    /// Writes hikes fetched from iCloud, skipping any this device is itself
    /// about to upload.
    ///
    /// The skip is the whole of the conflict policy on this side. A hike with
    /// an unsent local change is a hike whose user edited it here; letting the
    /// incoming copy overwrite it would lose that edit silently, whereas
    /// leaving it alone means the pending upload goes out and the two devices
    /// settle on it — through ``CKSyncEngine``'s own `serverRecordChanged`
    /// merge if the other end moved in the meantime.
    /// - Returns: The payloads that were written, so the caller knows which
    ///   server records it may now remember. A payload skipped for a pending
    ///   local change is deliberately not among them: remembering its record
    ///   would hand this device a change tag for data it never applied.
    func apply(
        hikes payloads: [HikeSyncPayload],
        skipping pending: Set<UUID>
    ) throws -> [HikeSyncPayload] {
        let applicable = payloads.filter { !pending.contains($0.id) }
        guard !applicable.isEmpty else { return [] }
        return try applyingRemoteChanges {
            let existing = hikesByID()
            for payload in applicable {
                guard let hike = existing[payload.id] else {
                    context.insert(payload.makeHike())
                    continue
                }
                // A draft is the recorder's, and the recorder is the only
                // thing allowed to write it. A remote copy of a hike that is
                // being walked right now would replace a live trace with a
                // stale one.
                guard !hike.isRecording else { continue }
                payload.apply(to: hike)
            }
            return applicable
        }
    }

    /// Attaches photo metadata whose pixels are already on disk.
    ///
    /// - Returns: The payloads whose hike this device hasn't seen yet, for the
    ///   caller to hold onto — see ``CloudSyncStateStore/deferPhoto(_:)``.
    func apply(photos payloads: [HikePhotoSyncPayload]) throws -> [HikePhotoSyncPayload] {
        guard !payloads.isEmpty else { return [] }
        return try applyingRemoteChanges {
            let existing = hikesByID()
            var unmatched: [HikePhotoSyncPayload] = []
            for payload in payloads {
                guard let hike = existing[payload.hikeID] else {
                    unmatched.append(payload)
                    continue
                }
                hike.addPhoto(payload.photo)
            }
            return unmatched
        }
    }

    /// Applies a deletion that arrived from another device.
    ///
    /// A record name is a bare UUID, so it is looked up as both a hike and a
    /// photo; exactly one of them will match anything. The hike path takes its
    /// pictures' files with it for the same reason the manual delete does —
    /// there is nothing left afterwards that could enumerate them.
    ///
    /// Tiles are deliberately not freed here. This device may hold offline
    /// coverage that other hikes still claim, and the launch-time sweep is
    /// what reconciles that; a delete arriving over the air is not a better
    /// moment to enumerate every route's tile grid than the one already
    /// chosen.
    func applyDeletions(recordNames: [String]) throws {
        let ids = Set(recordNames.compactMap(UUID.init(uuidString:)))
        guard !ids.isEmpty else { return }
        let orphaned = try applyingRemoteChanges { () throws -> [HikePhoto] in
            // Not `try?`. A failed fetch here would look exactly like "nothing
            // matched", and the caller would go on to forget these records as
            // though the deletion had been applied.
            let hikes = try context.fetch(FetchDescriptor<Hike>())
            var files: [HikePhoto] = []
            for hike in hikes {
                if ids.contains(hike.id) {
                    files.append(contentsOf: hike.photos)
                    context.delete(hike)
                    continue
                }
                let removed = hike.photos.filter { ids.contains($0.id) }
                guard !removed.isEmpty else { continue }
                for photo in removed {
                    hike.removePhoto(id: photo.id)
                }
                files.append(contentsOf: removed)
            }
            return files
        }
        // Erased only once the delete is committed. Doing it inside the block
        // would have a rollback restore hikes whose pictures were already on
        // their way out — files are not transactional, and the deletion is
        // fire-and-forget.
        HikePhotoImport.discardFiles(orphaned, from: photoStore)
    }

    /// The photos each changed hike currently holds.
    ///
    /// Takes SwiftData's own `PersistentIdentifier`s, because the caller is
    /// the save observer and that is what a save notification carries.
    /// Identifiers that aren't hikes, aren't registered any more, or belong to
    /// a recording draft simply don't appear in the result.
    func photosByHike(for identifiers: [PersistentIdentifier]) -> [UUID: [UUID]] {
        var changed: [UUID: [UUID]] = [:]
        for identifier in identifiers {
            guard let hike: Hike = context.registeredModel(for: identifier),
                  hike.isAttached,
                  !hike.isRecording
            else { continue }
            changed[hike.id] = hike.photos.map(\.id)
        }
        return changed
    }

    /// The same question asked about a hike that is about to be deleted, while
    /// it can still be asked — the ordering ``MapSheet``'s delete already uses
    /// for tiles and photo files, and for the same reason.
    func deletionIdentifiers(of hike: Hike) -> SyncableIdentifiers {
        guard hike.isAttached else { return SyncableIdentifiers() }
        return SyncableIdentifiers(
            hikeIDs: [hike.id],
            photoIDs: hike.photos.map(\.id)
        )
    }

    /// Every hike this device holds, drafts included.
    ///
    /// Feeds ``HikeSyncEngine/reconcile()``'s deletion half, which is why a
    /// failed fetch throws rather than answering with an empty set: an
    /// under-reported set here would delete real hikes out of iCloud.
    func allHikeIDs() throws -> Set<UUID> {
        Set(try context.fetch(FetchDescriptor<Hike>()).map(\.id))
    }

    private func hikesByID() -> [UUID: Hike] {
        guard let hikes = try? context.fetch(FetchDescriptor<Hike>()) else { return [:] }
        return Dictionary(hikes.map { ($0.id, $0) }) { first, _ in first }
    }
}
