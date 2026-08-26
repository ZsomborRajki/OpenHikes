//
//  HikeSyncEngine.swift
//  OpenHikes
//
//  The CloudKit half of sync: an `actor`, because `CKSyncEngineDelegate`
//  requires a `Sendable` delegate, and because everything it does — zlib,
//  archiving, file staging, record encoding — is work that has no business on
//  the main thread.
//
//  `CKSyncEngine` rather than SwiftData's own CloudKit mirroring, for one
//  reason that turned out to decide everything else: mirroring syncs a *row*,
//  and half of ``Hike`` describes files in this device's Application Support.
//  ``HikeSyncPayload`` has that argument in full. What the sync engine costs
//  in exchange is this file — the batching, the conflict merge and the state
//  bookkeeping that mirroring would have done invisibly.
//
//  Nothing here starts on its own. ``CloudSyncCoordinator`` owns the decision
//  about whether sync should be running at all, so that a test host, an
//  iCloud-less device and a user who turned it off all reach the same
//  do-nothing state by the same route.
//

import CloudKit
import Foundation
import os

actor HikeSyncEngine {
    static let logger = Logger(subsystem: "OpenHikes", category: "CloudSync")

    let applier: HikeSyncApplier
    let status: CloudSyncStatus

    /// Built on this actor, the first time anything asks for it.
    ///
    /// It used to be a `let` with `CloudSyncStateStore()` as its default
    /// argument — and a default argument is evaluated at the *call site*,
    /// which is ``CloudSyncCoordinator``'s initializer, which is
    /// ``OpenHikesModel/init`` on the main actor. That store's own
    /// initializer reads six files synchronously, one of them holding an
    /// archived `CKRecord` per hike *and* per photo, so a real library paid
    /// megabytes of main-thread I/O on the launch path `PERFORMANCE.md`
    /// measures — including on the launches where sync never runs at all,
    /// because the persistent store would not open or the user has the switch
    /// off. Every caller below is already `async` and already isolated here,
    /// so deferring it costs nothing.
    private var loadedStore: CloudSyncStateStore?

    var store: CloudSyncStateStore {
        if let loadedStore { return loadedStore }
        let created = CloudSyncStateStore()
        loadedStore = created
        return created
    }

    private let cloudContainer: CKContainer
    private var engine: CKSyncEngine?

    /// - Parameter store: Injectable so a suite gets its own directories
    ///   rather than the app's. `nil` — the app's case — builds one lazily;
    ///   see ``store``.
    init(
        applier: HikeSyncApplier,
        status: CloudSyncStatus,
        store: CloudSyncStateStore? = nil,
        cloudContainer: CKContainer = CKContainer(
            identifier: CloudSyncSchema.containerIdentifier
        )
    ) {
        self.applier = applier
        self.status = status
        loadedStore = store
        self.cloudContainer = cloudContainer
    }

    var isRunning: Bool { engine != nil }

    // MARK: - Lifecycle

    /// Brings the engine up, and makes sure iCloud knows about everything this
    /// device has that it hasn't acknowledged yet.
    ///
    /// Idempotent: the coordinator calls this on enable, on becoming active
    /// and after an account change, and only the first of those builds
    /// anything.
    func start() async {
        guard engine == nil else { return }

        let serialization = await store.loadStateSerialization()
        // Read *before* the engine exists. `CKSyncEngine` begins syncing the
        // moment it is constructed, and this actor is reentrant, so a fetch
        // can be serviced at the first `await` after it — at which point
        // ``locallyPendingHikeIDs()`` has to already know about these, or a
        // fetched copy overwrites the very edit they exist to protect.
        let pendingChanges = await pendingChanges()

        let configuration = CKSyncEngine.Configuration(
            database: cloudContainer.privateCloudDatabase,
            stateSerialization: serialization,
            delegate: self
        )
        let created = CKSyncEngine(configuration)
        engine = created
        if !pendingChanges.isEmpty {
            created.state.add(pendingRecordZoneChanges: pendingChanges)
        }

        // A first run has no zone. Saving it is a pending *database* change,
        // which the engine sends ahead of any record — without it every record
        // save would fail with `zoneNotFound` and be retried into the same
        // hole.
        if serialization == nil {
            created.state.add(
                pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: CloudSyncSchema.zoneID))]
            )
        }

        await store.sweepStagedAssets()
        await reconcile()
        await retryDeferredWrites()
    }

    /// The changes that were recorded while nothing was up to send them.
    ///
    /// The common case is ordinary: the app launches, a hike is renamed or
    /// deleted, and the engine only comes up once an `accountStatus()`
    /// round-trip returns. `CKSyncEngine` persists its own pending changes,
    /// but only from the moment it exists, so anything queued in that window
    /// would otherwise be dropped — and neither half is recoverable by
    /// reconciling: an edited hike already has a server record, and a deleted
    /// one has nothing left on this device to notice it is missing.
    private func pendingChanges() async -> [CKSyncEngine.PendingRecordZoneChange] {
        var changes: [CKSyncEngine.PendingRecordZoneChange] = await store
            .pendingSaveNames()
            .map { .saveRecord(CKRecord.ID(recordName: $0, zoneID: CloudSyncSchema.zoneID)) }
        changes.append(contentsOf: await store.pendingDeletionNames().map { name in
            .deleteRecord(CKRecord.ID(recordName: name, zoneID: CloudSyncSchema.zoneID))
        })
        return changes
    }

    /// Retries fetched hikes whose write to SwiftData failed on an earlier
    /// pass — see ``CloudSyncStateStore/deferHikes(_:)``.
    private func retryDeferredWrites() async {
        let waiting = await store.takeDeferredHikes()
        guard !waiting.isEmpty else { return }
        // `merging` rather than `uniqueKeysWithValues`: the queue is written by
        // a path that already collapses duplicates, but this one runs at
        // launch against whatever is on disk, and trapping here would take the
        // app down after `takeDeferredHikes()` had emptied the file.
        let archives = Dictionary(
            waiting.map { entry in (entry.payload.id.uuidString, entry.systemFields) }
        ) { _, later in later }
        let records = archives.compactMapValues { fields in
            fields.flatMap(CloudSyncStateStore.record(fromSystemFields:))
        }
        let payloads = waiting.map(\.payload)
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

    /// Stops syncing without forgetting anything, so starting again resumes
    /// from the same change token rather than re-downloading the world.
    func stop() async {
        engine = nil
        await flushState()
        await status.paused()
    }

    /// Writes anything the state store is holding behind its coalescing
    /// window.
    ///
    /// Deliberately does not build the store: a launch on which sync never ran
    /// has nothing to flush, and paying that initializer's file reads to
    /// discover it is the cost ``store`` exists to defer. Called from the
    /// engine's own idle events and from ``CloudSyncCoordinator``'s
    /// background and termination hooks.
    func flushState() async {
        await loadedStore?.flush()
    }

    /// Stops syncing *and* forgets where it had got to.
    ///
    /// What an account switch forces and what turning sync off does. The local
    /// store is untouched: everything discarded here is either re-derivable
    /// from the server or is bookkeeping about a server this device is no
    /// longer talking to.
    func reset(clearingDeletions: Bool = false) async {
        engine = nil
        await store.reset(clearingDeletions: clearingDeletions)
        await status.paused()
    }

    /// Pulls whatever is waiting.
    ///
    /// Normally unnecessary — the engine syncs on its own once a CloudKit push
    /// arrives — and necessary anyway on the two occasions a push doesn't:
    /// coming back to the foreground after the system dropped one, and the
    /// Simulator, which cannot register for remote notifications at all.
    func fetchChanges() async {
        guard let engine else { return }
        do {
            try await engine.fetchChanges()
        } catch {
            await report(error, whileDoing: "fetching changes")
        }
    }

    // MARK: - Queueing local changes

    /// Queues hikes whose contents changed, plus any of their photos iCloud
    /// has never acknowledged, minus any it holds that the hike no longer
    /// claims.
    ///
    /// A photo is only ever *sent* once: its pixels are immutable by
    /// construction and its metadata is decided when it is taken. Re-sending
    /// the lot every time a hike's title changed would put a walk's worth of
    /// megabytes back on the radio for a two-word edit.
    ///
    /// The removals are found by comparing what iCloud last acknowledged for
    /// this hike against what it holds now — see
    /// ``CloudSyncStateStore/photoRecordNames(ownedBy:)`` for why that memory
    /// has to exist. Doing it here rather than at the delete button means a
    /// picture removed with sync switched off is still noticed the next time
    /// its hike is touched.
    ///
    /// - Parameter photosByHike: Every changed hike, mapped to the photos it
    ///   currently holds. A hike with an empty array is a hike whose pictures
    ///   were all removed, which is a different statement from a hike that is
    ///   absent.
    func enqueue(photosByHike: [UUID: [UUID]]) async {
        var deletions: [CKRecord.ID] = []
        var saves = photosByHike.keys.map(CloudSyncSchema.hikeRecordID)

        // Two batched questions rather than one per photo and one per hike:
        // both of these are actor hops, and a first sync asks them about the
        // whole library.
        let candidates = photosByHike.values.joined()
            .map(CloudSyncSchema.photoRecordID)
        saves.append(contentsOf: await store.unacknowledged(Array(candidates)))

        let known = await store.photoRecordNames(
            ownedByAnyOf: Array(photosByHike.keys)
        )
        for (hikeID, photoIDs) in photosByHike {
            let current = Set(photoIDs.map(\.uuidString))
            for name in known[hikeID] ?? [] where !current.contains(name) {
                deletions.append(
                    CKRecord.ID(recordName: name, zoneID: CloudSyncSchema.zoneID)
                )
            }
        }
        guard !saves.isEmpty || !deletions.isEmpty else { return }

        // Written down whether or not the engine is up, for the reason
        // ``pendingChanges()`` gives: the window before it comes up is
        // one a user can rename a hike in, and an edit to an already-synced
        // hike is not something reconciliation asks about again.
        await store.rememberPendingSaves(saves.map(\.recordName))
        await store.rememberDeletions(deletions.map(\.recordName))

        guard let engine else { return }
        engine.state.add(
            pendingRecordZoneChanges: saves.map { .saveRecord($0) }
                + deletions.map { .deleteRecord($0) }
        )
    }

    /// Queues deletions.
    ///
    /// The photos are named explicitly even though the server would cascade
    /// them from the hike's `.deleteSelf` reference: the cascade is what
    /// catches pictures *this* device never saw, and naming the ones it did
    /// see is what keeps its own state consistent without waiting to be told.
    func enqueueDeletions(hikeIDs: [UUID], photoIDs: [UUID]) async {
        let recordIDs = hikeIDs.map(CloudSyncSchema.hikeRecordID)
            + photoIDs.map(CloudSyncSchema.photoRecordID)
        guard !recordIDs.isEmpty else { return }

        // Written down before anything is attempted, and kept until the server
        // confirms. The engine is *not* up during a normal launch — the
        // coordinator waits on an account round-trip first — and it is not up
        // at all when sync is switched off, so a deletion that only existed as
        // a pending change would be lost in both cases.
        await store.rememberDeletions(recordIDs.map(\.recordName))
        // A queued save for a hike that is now deleted has nothing left to
        // read. Left behind it would be re-offered on every launch forever.
        await store.forgetPendingSaves(recordIDs.map(\.recordName))
        guard let engine else { return }
        engine.state.add(pendingRecordZoneChanges: recordIDs.map { .deleteRecord($0) })
    }

    /// Sends anything this device holds that the server has never acknowledged.
    ///
    /// This is what makes a first sync upload an existing library, and what
    /// picks up a hike recorded while sync was switched off. It asks the
    /// question the cheap way — "is there a server record for this?" — rather
    /// than by comparing contents, and asks it about the whole library in one
    /// hop, so a launch with nothing new to say costs one dictionary lookup
    /// per hike and two suspensions in total.
    func reconcile() async {
        guard let engine else { return }

        let identifiers = await applier.syncableIdentifiers()
        let candidates = identifiers.hikeIDs.map(CloudSyncSchema.hikeRecordID)
            + identifiers.photoIDs.map(CloudSyncSchema.photoRecordID)
        var changes = await store.unacknowledged(candidates)
            .map(CKSyncEngine.PendingRecordZoneChange.saveRecord)

        changes.append(contentsOf: await orphanedRecordDeletions())

        guard !changes.isEmpty else { return }
        engine.state.add(pendingRecordZoneChanges: changes)
    }

    /// The other direction: records iCloud holds that this device doesn't.
    ///
    /// A hike the user deleted here leaves nothing behind that a scan of the
    /// local store could notice, so the tombstones carry it — but a tombstone
    /// is only written when the deletion goes through this app, and a launch
    /// interrupted between the two would still leave the record up. Comparing
    /// the acknowledged hike records against what is actually here closes
    /// that, and closes the case where iCloud is ahead of a device that has
    /// legitimately deleted something.
    ///
    /// Deliberately not applied to photo records: a photo has no top-level
    /// model, so "no local model for this record" is its normal state.
    /// Removals of those are found by ``enqueue(photosByHike:)`` instead.
    private func orphanedRecordDeletions() async -> [CKSyncEngine.PendingRecordZoneChange] {
        // A failed fetch reconciles nothing. Passing an incomplete set here
        // would read every hike as deleted and empty the zone.
        guard let localIDs = try? await applier.allHikeIDs() else { return [] }
        let orphans = await store.orphanedHikeRecordNames(localHikeIDs: localIDs)
        guard !orphans.isEmpty else { return [] }
        // A store that answers "no hikes at all" while iCloud is remembered as
        // holding some is far more likely to be a store that failed to open
        // than a library the user emptied — and emptying it one hike at a time
        // is already covered, by the tombstone each of those deletions wrote.
        // Refusing here costs nothing and is the difference between a bad
        // launch and a wiped account.
        guard !localIDs.isEmpty else {
            Self.logger.error(
                """
                Refusing to reconcile \(orphans.count, privacy: .public) iCloud \
                hike records against a local store with no hikes in it.
                """
            )
            return []
        }
        await store.rememberDeletions(orphans)
        return orphans.map { name in
            .deleteRecord(CKRecord.ID(recordName: name, zoneID: CloudSyncSchema.zoneID))
        }
    }

    // MARK: - Reporting

    func report(_ error: any Error, whileDoing activity: String) async {
        Self.logger.error(
            """
            Sync failed while \(activity, privacy: .public): \
            \(error.localizedDescription, privacy: .public)
            """
        )
        await status.failed(error.localizedDescription)
    }

    /// The photo files held for a hike that hasn't arrived yet, so the
    /// launch-time orphan sweep doesn't mistake them for abandoned bytes.
    ///
    /// `nil` when the deferred-photo file could not be read, which authorizes
    /// no sweep at all — the rule the tile and photo claim sets already
    /// follow, and for the same reason.
    func deferredPhotoClaims() async -> Set<String>? { // swiftlint:disable:this discouraged_optional_collection
        await store.deferredPhotoFileNames()
    }

    /// The hikes this device is itself about to upload, which a fetched copy
    /// must not overwrite — see ``HikeSyncApplier/apply(hikes:skipping:)``.
    func locallyPendingHikeIDs() -> Set<UUID> {
        guard let engine else { return [] }
        return Set(
            engine.state.pendingRecordZoneChanges.compactMap { change in
                guard case .saveRecord(let recordID) = change else { return nil }
                return UUID(uuidString: recordID.recordName)
            }
        )
    }
}
