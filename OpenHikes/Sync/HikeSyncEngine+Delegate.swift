//
//  HikeSyncEngine+Delegate.swift
//  OpenHikes
//
//  The two methods `CKSyncEngine` calls, and what they do with what they are
//  handed.
//
//  Split from the engine's own lifecycle for length rather than for taste: the
//  delegate is the part that has to be read against Apple's event list, and
//  the part above it is the part that has to be read against this app.
//

import CloudKit
import Foundation
import os

extension HikeSyncEngine: CKSyncEngineDelegate {
    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .stateUpdate(let update):
            // Persisted the moment it arrives, and before anything else can
            // await: this blob *is* the record of which server changes have
            // been applied, and a launch that lost it re-downloads the world,
            // while a launch that saved one that ran ahead of the data it
            // describes never sees those changes again.
            await store.save(stateSerialization: update.stateSerialization)
        case .accountChange(let change):
            await handleAccountChange(change)
        case .fetchedDatabaseChanges(let changes):
            await handleDatabaseChanges(changes, syncEngine: syncEngine)
        case .fetchedRecordZoneChanges(let changes):
            await applyFetched(changes, syncEngine: syncEngine)
        case .sentRecordZoneChanges(let sent):
            await handleSent(sent, syncEngine: syncEngine)
        case .willFetchChanges, .willSendChanges:
            await status.began()
        case .didFetchChanges, .didSendChanges:
            await status.finished()
        default:
            break
        }
    }

    func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        // Filtering by the context's scope is not optional: returning a change
        // the caller didn't ask for fails the whole batch with
        // `invalidArguments`.
        let scoped = syncEngine.state.pendingRecordZoneChanges.filter { change in
            context.options.scope.contains(change)
        }
        guard !scoped.isEmpty else { return nil }

        let names = Set(
            scoped.compactMap { change -> String? in
                guard case .saveRecord(let recordID) = change else { return nil }
                return recordID.recordName
            }
        )
        // One main-actor hop for the whole batch — up to 250 records — rather
        // than one per record. What comes back is `Sendable` snapshots, so the
        // expensive part below runs off the main thread.
        //
        // `nil` means the fetch itself failed, which is a different statement
        // from "none of these exist": sending nothing this round leaves the
        // pending changes alone, so the next batch asks again.
        guard let uploads = try? await applier.uploads(for: names) else { return nil }
        let store = store

        return await CKSyncEngine.RecordZoneChangeBatch(
            pendingChanges: scoped
        ) { recordID in
            guard let upload = uploads[recordID.recordName] else {
                // Nothing local answers to this name any more — a hike deleted
                // between the queueing and the send. Dropping the pending
                // change as well as the record stops it being offered again on
                // every subsequent batch.
                syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
                await store.forgetPendingSaves([recordID.recordName])
                return nil
            }
            switch await Self.record(for: recordID, upload: upload, store: store) {
            case .record(let record):
                return record
            case .unavailable(let reason):
                // Nothing a retry would change: an unencodable route, or a
                // photo whose file is gone. Left pending it would be offered
                // on every batch forever, so it is dropped and reported.
                syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
                await store.forgetPendingSaves([recordID.recordName])
                await self.reportUnsendable(recordID, reason: reason)
                return nil
            }
        }
    }

    func reportUnsendable(_ recordID: CKRecord.ID, reason: String) async {
        Self.logger.error(
            """
            Dropped \(recordID.recordName, privacy: .public) from the upload queue: \
            \(reason, privacy: .public)
            """
        )
        await status.failed(reason)
    }
}

// MARK: - Building records

extension HikeSyncEngine {
    /// Fills the last record the server acknowledged, or a new one.
    ///
    /// Reusing the acknowledged record is what carries its change tag, which
    /// is what lets CloudKit tell "I edited the version you have" from "I am
    /// overwriting whatever is there". Without it every save would look like
    /// the second, and the loser of a race would simply vanish.
    static func record(
        for recordID: CKRecord.ID,
        upload: PendingUpload,
        store: CloudSyncStateStore
    ) async -> RecordOutcome {
        switch upload {
        case .hike(let payload):
            let record = await store.lastKnownRecord(id: recordID)
                ?? CKRecord(recordType: CloudSyncSchema.RecordType.hike, recordID: recordID)
            do {
                try HikeCloudRecord.encode(payload, into: record, staging: store.staging)
            } catch {
                return .unavailable("this hike's route could not be encoded for iCloud")
            }
            return .record(record)
        case let .photo(payload, imageURL):
            // A photo whose file is gone is a photo there is nothing to
            // upload for, and no number of retries brings the bytes back.
            guard FileManager.default.fileExists(atPath: imageURL.path) else {
                return .unavailable("a photo's file is missing")
            }
            let record = await store.lastKnownRecord(id: recordID)
                ?? CKRecord(recordType: CloudSyncSchema.RecordType.photo, recordID: recordID)
            HikePhotoCloudRecord.encode(payload, into: record, imageURL: imageURL)
            return .record(record)
        }
    }

    /// Why a queued change produced no record — the distinction the batch
    /// provider needs, because one of the two answers means "stop asking".
    nonisolated enum RecordOutcome: Sendable {
        case record(CKRecord)
        case unavailable(String)
    }
}

// MARK: - Fetching

extension HikeSyncEngine {
    /// Applies one batch of server changes: hikes first, then photos, then
    /// deletions.
    ///
    /// The order is the point. A photo record can arrive before the hike it
    /// belongs to — CloudKit orders changes within a zone but promises nothing
    /// about which of them share a batch — so anything still unmatched at the
    /// end is held rather than dropped.
    func applyFetched(
        _ changes: CKSyncEngine.Event.FetchedRecordZoneChanges,
        syncEngine: CKSyncEngine
    ) async {
        var batch = FetchedBatch()
        for modification in changes.modifications {
            await decode(modification.record, into: &batch)
        }

        await writeHikes(in: batch)
        await writePhotos(in: batch)

        await writeDeletions(changes.deletions.map(\.recordID.recordName))
    }

    /// Applies deletions fetched from iCloud, together with any earlier ones
    /// that could not be written.
    ///
    /// Held rather than logged for the same reason a fetched hike is: the
    /// change token has moved past that deletion and the server will not
    /// mention it again, so a device that dropped one keeps a hike that was
    /// deleted everywhere else — and keeps re-uploading it.
    private func writeDeletions(_ recordNames: [String]) async {
        let names = await store.takeDeferredDeletions() + recordNames
        guard !names.isEmpty else { return }
        do {
            try await applier.applyDeletions(recordNames: names)
            await store.forgetRecords(
                ids: names.map { CKRecord.ID(recordName: $0, zoneID: CloudSyncSchema.zoneID) }
            )
        } catch {
            await store.deferDeletions(names)
            await report(error, whileDoing: "applying deletions fetched from iCloud")
        }
    }

    /// One batch's records, decoded, each paired with the record it came from
    /// so the record can be remembered *after* its data is written.
    private struct FetchedBatch {
        var hikes: [HikeSyncPayload] = []
        var photos: [HikePhotoSyncPayload] = []
        var hikeRecords: [String: CKRecord] = [:]
        var photoRecords: [String: CKRecord] = [:]
    }

    private func decode(_ record: CKRecord, into batch: inout FetchedBatch) async {
        switch record.recordType {
        case CloudSyncSchema.RecordType.hike:
            do {
                let payload = try HikeCloudRecord.decode(record)
                batch.hikes.append(payload)
                batch.hikeRecords[payload.id.uuidString] = record
            } catch {
                Self.logger.error(
                    """
                    Skipped an unreadable hike record: \
                    \(String(describing: error), privacy: .public)
                    """
                )
            }
        case CloudSyncSchema.RecordType.photo:
            guard let payload = HikePhotoCloudRecord.decode(record) else { return }
            await installPixels(of: payload, from: record)
            batch.photos.append(payload)
            batch.photoRecords[payload.id.uuidString] = record
        default:
            return
        }
    }

    /// Writes the batch's hikes, and remembers only the records that landed.
    ///
    /// Remembering first would hand this device a change tag for a hike it
    /// never wrote, and the change token has already moved past that record —
    /// the server will not offer it again. A failure therefore has to leave
    /// the payloads somewhere durable instead, together with their records:
    /// see ``Deferred``.
    /// Collapses payloads naming the same record, keeping the later one.
    ///
    /// `waiting + batch` can carry an id twice: something deferred on an
    /// earlier pass that has since changed again arrives in both halves. Left
    /// alone, a failed write defers both copies, and the next launch builds a
    /// record lookup from them with `Dictionary(uniqueKeysWithValues:)` —
    /// which traps, *after* `takeDeferredHikes()` has already written the
    /// emptied queue to disk. A crash and the loss of the very payloads the
    /// deferral existed to protect. The batch half is the fresher of the two,
    /// which is why later wins.
    private static func deduplicated<Payload>(
        _ payloads: [Payload],
        by id: (Payload) -> UUID
    ) -> [Payload] {
        var seen = Set<UUID>()
        var newestFirst: [Payload] = []
        newestFirst.reserveCapacity(payloads.count)
        for payload in payloads.reversed() where seen.insert(id(payload)).inserted {
            newestFirst.append(payload)
        }
        return newestFirst.reversed()
    }

    private func writeHikes(in batch: FetchedBatch) async {
        let waiting = await store.takeDeferredHikes()
        var records = batch.hikeRecords
        for entry in waiting where records[entry.payload.id.uuidString] == nil {
            records[entry.payload.id.uuidString] = entry.systemFields
                .flatMap(CloudSyncStateStore.record(fromSystemFields:))
        }
        let payloads = Self.deduplicated(waiting.map(\.payload) + batch.hikes, by: \.id)
        guard !payloads.isEmpty else { return }
        do {
            let written = try await applier.apply(
                hikes: payloads,
                skipping: locallyPendingHikeIDs()
            )
            await store.remember(written.compactMap { records[$0.id.uuidString] })
        } catch {
            await store.deferHikes(payloads, records: records)
            await report(error, whileDoing: "writing hikes fetched from iCloud")
        }
    }

    /// Attaches the batch's photos, together with everything that has ever
    /// been waiting for a hike: the hike a photo was waiting for may well be
    /// in *this* batch.
    private func writePhotos(in batch: FetchedBatch) async {
        let waiting = await store.takeDeferredPhotos()
        var records = batch.photoRecords
        for entry in waiting where records[entry.payload.id.uuidString] == nil {
            guard let record = entry.systemFields
                .flatMap(CloudSyncStateStore.record(fromSystemFields:)) else { continue }
            // System fields carry identity and change tag, and no user data —
            // but ``CloudSyncStateStore/remember(_:)`` reads this one field to
            // index which hike owns the photo. Without it a deferred photo
            // lands with a change tag and no owner, and removing it later
            // never queues the iCloud deletion, so it survives on every other
            // device.
            record[CloudSyncSchema.PhotoField.hikeID] = entry.payload.hikeID.uuidString
            records[entry.payload.id.uuidString] = record
        }
        let payloads = Self.deduplicated(waiting.map(\.payload) + batch.photos, by: \.id)
        guard !payloads.isEmpty else { return }
        do {
            let unmatched = try await applier.apply(photos: payloads)
            // Only the ones that were actually attached. Remembering a record
            // for a photo handed back unmatched is the very thing this
            // method's counterpart above refuses to do: a change tag for data
            // this device never wrote, against a token the server has already
            // moved past.
            let deferred = Set(unmatched.map(\.id))
            await store.remember(
                payloads
                    .filter { !deferred.contains($0.id) }
                    .compactMap { records[$0.id.uuidString] }
            )
            for photo in unmatched {
                await store.deferPhoto(photo, from: records[photo.id.uuidString])
            }
        } catch {
            for photo in payloads {
                await store.deferPhoto(photo, from: records[photo.id.uuidString])
            }
            await report(error, whileDoing: "writing photos fetched from iCloud")
        }
    }

    /// Copies a fetched photo's bytes into the app's own storage immediately.
    ///
    /// "Immediately" is Apple's word, not a preference: CloudKit stages a
    /// fetched asset in a scratch location it reclaims on its own schedule, so
    /// a file read later is a file that may not be there. Skipped when the
    /// device already holds those pixels, which is the common case for the
    /// device that took the picture in the first place.
    private func installPixels(
        of payload: HikePhotoSyncPayload,
        from record: CKRecord
    ) async {
        guard let url = HikePhotoCloudRecord.imageURL(in: record) else { return }
        await Self.install(from: url, as: payload.photo)
    }

    @concurrent
    private static func install(from url: URL, as photo: HikePhoto) async {
        let store = HikePhotoStore.shared
        guard !store.hasImage(for: photo) else { return }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return }
        store.install(data, as: photo)
    }
}

// MARK: - Sending

extension HikeSyncEngine {
    /// Records what the server accepted, and decides what to do about what it
    /// didn't.
    ///
    /// Three kinds of failure arrive here, and only the first is worth telling
    /// anyone about. The ones needing app-specific knowledge — a record
    /// somebody else edited first, a zone that no longer exists — are named
    /// below. The rest are classified by ``CloudSyncFailure``: the transient
    /// ones ``CKSyncEngine`` is already retrying are logged and left alone,
    /// and the ones that failed through no fault of their own are queued
    /// again. A failure being *delivered* here says nothing about whether it
    /// is the user's problem.
    func handleSent(
        _ sent: CKSyncEngine.Event.SentRecordZoneChanges,
        syncEngine: CKSyncEngine
    ) async {
        await store.rememberSent(sent.savedRecords)
        for record in sent.savedRecords {
            // Safe only now: CloudKit read this file when it sent the batch,
            // not when the batch was built, so anything earlier would have
            // deleted a route out from under its own upload.
            store.staging.discardFiles(prefixed: record.recordID.recordName)
        }
        if !sent.deletedRecordIDs.isEmpty {
            await store.forgetRecords(ids: sent.deletedRecordIDs)
            await store.forgetDeletions(sent.deletedRecordIDs.map(\.recordName))
        }

        var retryRecords: [CKSyncEngine.PendingRecordZoneChange] = []
        var retryZones: [CKSyncEngine.PendingDatabaseChange] = []
        await handleFailedSaves(sent, into: &retryRecords, zones: &retryZones)
        await handleFailedDeletes(sent, into: &retryRecords)

        if !retryZones.isEmpty {
            syncEngine.state.add(pendingDatabaseChanges: retryZones)
        }
        if !retryRecords.isEmpty {
            syncEngine.state.add(pendingRecordZoneChanges: retryRecords)
        }
    }

    private func handleFailedSaves(
        _ sent: CKSyncEngine.Event.SentRecordZoneChanges,
        into retryRecords: inout [CKSyncEngine.PendingRecordZoneChange],
        zones retryZones: inout [CKSyncEngine.PendingDatabaseChange]
    ) async {
        for failure in sent.failedRecordSaves {
            let recordID = failure.record.recordID
            switch failure.error.code {
            case .serverRecordChanged:
                // Somebody else got there first. Take their record for its
                // change tag and queue the save again — the next batch fills
                // this device's fields into it, which is the merge.
                guard let serverRecord = failure.error.serverRecord else { continue }
                await store.remember(serverRecord)
                retryRecords.append(.saveRecord(recordID))
            case .zoneNotFound, .userDeletedZone:
                // The zone was deleted out from under us — by another device,
                // or by the user clearing this app's data in iCloud settings,
                // which is the second code and is otherwise the same
                // situation. Recreate it and start over from a record with no
                // change tag, because the one this device remembers refers to
                // a zone that no longer exists. Without this the save fails
                // identically forever and sync never recovers on this device.
                await store.forgetRecord(id: recordID)
                retryZones.append(.saveZone(CKRecordZone(zoneID: recordID.zoneID)))
                retryRecords.append(.saveRecord(recordID))
            case .unknownItem:
                // The record was deleted server-side while this device still
                // held its tag. Forgetting the tag turns the retry into an
                // insert.
                await store.forgetRecord(id: recordID)
                retryRecords.append(.saveRecord(recordID))
            default:
                switch CloudSyncFailure.response(to: failure.error.code) {
                case .ignore:
                    Self.logger.debug(
                        """
                        \(recordID.recordName, privacy: .public) will be retried by the sync engine: \
                        \(failure.error.localizedDescription, privacy: .public)
                        """
                    )
                case .retry:
                    // Not reported, and above all not dropped: the engine has
                    // already consumed the pending change, so without this the
                    // save waits for the next launch to replay it.
                    retryRecords.append(.saveRecord(recordID))
                case .report:
                    await report(failure.error, whileDoing: "saving a record")
                }
            }
        }
    }

    private func handleFailedDeletes(
        _ sent: CKSyncEngine.Event.SentRecordZoneChanges,
        into retryRecords: inout [CKSyncEngine.PendingRecordZoneChange]
    ) async {
        for failure in sent.failedRecordDeletes {
            let recordID = failure.key
            switch failure.value.code {
            case .unknownItem:
                // Already gone. Exactly the outcome that was asked for, so the
                // tombstone can go too.
                await store.forgetRecords(ids: [recordID])
                await store.forgetDeletions([recordID.recordName])
            default:
                // Queued again rather than dropped: a deletion that is not
                // re-sent leaves the record in iCloud to be downloaded back
                // onto every device, which reads as the hike undeleting itself.
                // The exception is a failure the engine is already retrying,
                // where the pending change is still its own and re-adding it
                // would only trade one alert the user cannot act on for two.
                switch CloudSyncFailure.response(to: failure.value.code) {
                case .ignore:
                    Self.logger.debug(
                        """
                        Deleting \(recordID.recordName, privacy: .public) will be retried by the sync engine: \
                        \(failure.value.localizedDescription, privacy: .public)
                        """
                    )
                case .retry:
                    retryRecords.append(.deleteRecord(recordID))
                case .report:
                    await report(failure.value, whileDoing: "deleting a record")
                    retryRecords.append(.deleteRecord(recordID))
                }
            }
        }
    }
}

// MARK: - Account and zone changes

extension HikeSyncEngine {
    func handleAccountChange(_ change: CKSyncEngine.Event.AccountChange) async {
        switch change.changeType {
        case .signIn:
            await status.began()
            await reconcile()
        case .signOut:
            // The state describes a server this device is no longer talking
            // to. The hikes stay; they were always the local copy.
            await reset()
        case .switchAccounts:
            // The tombstones go with it: they name records in the account this
            // device has stopped talking to, and the one it has moved to has
            // never heard of them.
            await reset(clearingDeletions: true)
            await start()
        default:
            break
        }
    }

    /// A zone deleted elsewhere — by another device, or by the user clearing
    /// this app's data in iCloud settings.
    ///
    /// It does *not* delete anything locally. "Remove this app's iCloud data"
    /// is a statement about iCloud, and answering it by wiping every hike off
    /// the phone would be the single worst thing this feature could do. The
    /// zone is recreated and the library uploaded again.
    func handleDatabaseChanges(
        _ changes: CKSyncEngine.Event.FetchedDatabaseChanges,
        syncEngine: CKSyncEngine
    ) async {
        let ours = changes.deletions.contains { deletion in
            deletion.zoneID == CloudSyncSchema.zoneID
        }
        guard ours else { return }
        Self.logger.notice("The hikes zone was deleted in iCloud; re-uploading this device's copy.")
        await store.reset()
        syncEngine.state.add(
            pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: CloudSyncSchema.zoneID))]
        )
        await reconcile()
    }
}
