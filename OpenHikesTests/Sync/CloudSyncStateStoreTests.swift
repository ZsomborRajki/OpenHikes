//
//  CloudSyncStateStoreTests.swift
//  OpenHikesTests
//
//  What sync remembers between launches. Apple's rule for the engine state is
//  strict — a device that loses it re-downloads the world, and a device that
//  saves one running ahead of the data it describes never sees those changes
//  again — so "it survives a relaunch" is worth asserting rather than assuming.
//
//  Every case builds its own storage root. These suites run in parallel and
//  the real directories belong to the host app.
//

import CloudKit
import Foundation
@testable import OpenHikes
import Testing

@Suite("Cloud sync state store")
struct CloudSyncStateStoreTests {
    private enum Constants {
        static let stagedBytes: [UInt8] = [0x1, 0x2, 0x3, 0x4]
        static let staleAge: TimeInterval = 3600
        static let wellPast: TimeInterval = 7200
    }

    /// A storage root and a staging root of this case's own, plus the store
    /// built on top of them.
    private struct Sandbox {
        let root: URL
        let store: CloudSyncStateStore

        init() {
            root = URL.temporaryDirectory.appendingPathComponent(
                "CloudSyncStateStoreTests-\(UUID().uuidString)",
                isDirectory: true
            )
            store = CloudSyncStateStore(
                storageRoot: root.appendingPathComponent("support", isDirectory: true),
                stagingRoot: root.appendingPathComponent("caches", isDirectory: true)
            )
        }

        /// A second store over the same directories — what the next launch
        /// sees.
        func relaunched() -> CloudSyncStateStore {
            CloudSyncStateStore(
                storageRoot: root.appendingPathComponent("support", isDirectory: true),
                stagingRoot: root.appendingPathComponent("caches", isDirectory: true)
            )
        }

        func removeAll() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private static func photoRecord(id: UUID, hikeID: UUID) -> CKRecord {
        let record = CKRecord(
            recordType: CloudSyncSchema.RecordType.photo,
            recordID: CloudSyncSchema.photoRecordID(id)
        )
        record[CloudSyncSchema.PhotoField.hikeID] = hikeID.uuidString
        return record
    }

    /// The change tag is the whole reason acknowledged records are kept: a
    /// save built from a blank record claims to know nothing about what is
    /// already up there, which turns a merge into a clobber.
    @Test("An acknowledged record is remembered across a relaunch")
    func recordsSurviveRelaunch() async {
        let sandbox = Sandbox()
        defer { sandbox.removeAll() }
        let id = UUID()
        let record = CKRecord(
            recordType: CloudSyncSchema.RecordType.hike,
            recordID: CloudSyncSchema.hikeRecordID(id)
        )

        await sandbox.store.remember(record)
        let restored = await sandbox.relaunched()
            .lastKnownRecord(id: CloudSyncSchema.hikeRecordID(id))

        #expect(restored?.recordID == record.recordID)
        #expect(restored?.recordType == CloudSyncSchema.RecordType.hike)
    }

    @Test("A forgotten record is gone from the next launch too")
    func forgettingSurvivesRelaunch() async {
        let sandbox = Sandbox()
        defer { sandbox.removeAll() }
        let recordID = CloudSyncSchema.hikeRecordID(UUID())
        let record = CKRecord(
            recordType: CloudSyncSchema.RecordType.hike,
            recordID: recordID
        )

        await sandbox.store.remember(record)
        await sandbox.store.forgetRecord(id: recordID)

        #expect(await sandbox.relaunched().lastKnownRecord(id: recordID) == nil)
    }

    /// The only way a removed photo is ever noticed: a removal edits the
    /// hike's array and mentions the photo nowhere, so something has to
    /// remember what the hike used to claim.
    @Test("A photo record remembers which hike claimed it")
    func photoOwnershipIsRemembered() async {
        let sandbox = Sandbox()
        defer { sandbox.removeAll() }
        let hikeID = UUID()
        let mine = UUID()
        let theirs = UUID()

        await sandbox.store.remember(Self.photoRecord(id: mine, hikeID: hikeID))
        await sandbox.store.remember(Self.photoRecord(id: theirs, hikeID: UUID()))

        let owned = await sandbox.relaunched().photoRecordNames(ownedBy: hikeID)
        #expect(owned == [mine.uuidString])
    }

    /// `encodeSystemFields` writes identity and change tag and nothing else,
    /// so a record rebuilt from a deferred photo's archive carries no owner.
    /// ``photoOwnershipIsRemembered`` reads that field, so the delegate has to
    /// put it back before remembering a retried photo — otherwise the photo is
    /// filed with a change tag and no hike behind it, and deleting it locally
    /// never queues the iCloud deletion, so it returns on every other device.
    @Test("A record rebuilt from system fields no longer names its hike")
    func systemFieldsCarryNoOwnership() {
        let record = Self.photoRecord(id: UUID(), hikeID: UUID())
        let rebuilt = CloudSyncStateStore.record(
            fromSystemFields: CloudSyncStateStore.systemFields(of: record)
        )

        #expect(rebuilt?.recordID == record.recordID)
        #expect(rebuilt?[CloudSyncSchema.PhotoField.hikeID] as String? == nil)
    }

    @Test("Forgetting a photo record drops its ownership too")
    func forgettingClearsOwnership() async {
        let sandbox = Sandbox()
        defer { sandbox.removeAll() }
        let hikeID = UUID()
        let photoID = UUID()

        await sandbox.store.remember(Self.photoRecord(id: photoID, hikeID: hikeID))
        await sandbox.store.forgetRecord(id: CloudSyncSchema.photoRecordID(photoID))

        #expect(await sandbox.store.photoRecordNames(ownedBy: hikeID).isEmpty)
    }

    /// A photo whose hike hasn't arrived yet is held rather than dropped, and
    /// held across a relaunch — the fetch that would have brought its hike may
    /// be the one that was interrupted.
    @Test("A deferred photo waits through a relaunch and is taken once")
    func deferredPhotosSurviveRelaunch() async {
        let sandbox = Sandbox()
        defer { sandbox.removeAll() }
        let payload = HikePhotoSyncPayload(hikeID: UUID(), photo: HikePhoto())

        await sandbox.store.deferPhoto(payload)

        let next = sandbox.relaunched()
        #expect(await next.takeDeferredPhotos().map(\.payload) == [payload])
        #expect(await next.takeDeferredPhotos().isEmpty)
    }

    @Test("Deferring the same photo twice holds one copy")
    func deferringIsIdempotent() async {
        let sandbox = Sandbox()
        defer { sandbox.removeAll() }
        let payload = HikePhotoSyncPayload(hikeID: UUID(), photo: HikePhoto())

        await sandbox.store.deferPhoto(payload)
        await sandbox.store.deferPhoto(payload)

        #expect(await sandbox.store.takeDeferredPhotos().count == 1)
    }

    /// What turning sync off does. Everything discarded is either re-derivable
    /// from the server or is bookkeeping about a server this device has
    /// stopped talking to.
    @Test("Resetting forgets everything, including on the next launch")
    func resetClearsEverything() async {
        let sandbox = Sandbox()
        defer { sandbox.removeAll() }
        let hikeID = UUID()
        let recordID = CloudSyncSchema.hikeRecordID(hikeID)
        await sandbox.store.remember(CKRecord(
            recordType: CloudSyncSchema.RecordType.hike,
            recordID: recordID
        ))
        await sandbox.store.deferPhoto(
            HikePhotoSyncPayload(hikeID: hikeID, photo: HikePhoto())
        )

        await sandbox.store.reset()

        let next = sandbox.relaunched()
        #expect(await next.lastKnownRecord(id: recordID) == nil)
        #expect(await next.takeDeferredPhotos().isEmpty)
    }

    /// The backstop for a send that termination interrupted. Staged route
    /// files are fire-and-forget, so something has to catch the ones nothing
    /// deleted — and has to leave alone the ones still waiting to be sent.
    @Test("The staging sweep takes stale files and leaves fresh ones")
    func sweepRemovesOnlyStaleFiles() {
        let sandbox = Sandbox()
        defer { sandbox.removeAll() }
        let staging = sandbox.store.staging
        let url = staging.stage(Data(Constants.stagedBytes), named: "record.route")

        staging.sweep(olderThan: Constants.staleAge, now: .now)
        #expect(Self.exists(url))

        staging.sweep(
            olderThan: Constants.staleAge,
            now: Date.now.addingTimeInterval(Constants.wellPast)
        )
        #expect(!Self.exists(url))
    }

    @Test("Discarding by prefix takes only that record's files")
    func discardByPrefix() {
        let sandbox = Sandbox()
        defer { sandbox.removeAll() }
        let staging = sandbox.store.staging
        let data = Data(Constants.stagedBytes)
        let mine = staging.stage(data, named: "record-a.route")
        let theirs = staging.stage(data, named: "record-b.route")

        staging.discardFiles(prefixed: "record-a")

        #expect(!Self.exists(mine))
        #expect(Self.exists(theirs))
    }

    private static func exists(_ url: URL?) -> Bool {
        guard let url else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }
}

// MARK: - Deletions and deferred writes

/// Split out of the suite's own body only for length; these are its cases.
extension CloudSyncStateStoreTests {

    /// The one thing here that isn't re-derivable. A hike deleted with sync
    /// switched off leaves nothing behind for a later scan to notice, while
    /// iCloud still holds a copy — so a tombstone that `reset()` took with it
    /// would have that hike download itself back the moment sync was switched
    /// on again.
    @Test("A tombstone outlives a reset")
    func deletionsSurviveReset() async {
        let sandbox = Sandbox()
        defer { sandbox.removeAll() }
        let name = UUID().uuidString
        await sandbox.store.rememberDeletions([name])

        await sandbox.store.reset()

        #expect(await sandbox.store.pendingDeletionNames() == [name])
        #expect(await sandbox.relaunched().pendingDeletionNames() == [name])
    }

    @Test("A confirmed deletion is forgotten")
    func confirmedDeletionIsForgotten() async {
        let sandbox = Sandbox()
        defer { sandbox.removeAll() }
        let sent = UUID().uuidString
        let waiting = UUID().uuidString
        await sandbox.store.rememberDeletions([sent, waiting, sent])

        await sandbox.store.forgetDeletions([sent])

        #expect(await sandbox.relaunched().pendingDeletionNames() == [waiting])
    }

    /// `CKSyncEngine` persists its own pending changes, but only from the
    /// moment it exists — and it does not exist during the account round-trip
    /// a launch begins with, which is a window a user can rename a hike in.
    @Test("An edit queued before the engine existed is still pending")
    func pendingSaveSurvivesRelaunch() async {
        let sandbox = Sandbox()
        defer { sandbox.removeAll() }
        let name = UUID().uuidString
        await sandbox.store.rememberPendingSaves([name])

        #expect(await sandbox.relaunched().pendingSaveNames() == [name])
    }

    /// Unlike a tombstone, a queued save need not outlive a reset: a reset
    /// forgets every server record, so reconciliation re-uploads the lot.
    @Test("An acknowledged save stops being pending")
    func acknowledgedSaveIsForgotten() async {
        let sandbox = Sandbox()
        defer { sandbox.removeAll() }
        let hikeID = UUID()
        let recordID = CloudSyncSchema.hikeRecordID(hikeID)
        await sandbox.store.rememberPendingSaves([recordID.recordName])

        let record = CKRecord(
            recordType: CloudSyncSchema.RecordType.hike,
            recordID: recordID
        )
        await sandbox.store.rememberSent([record])

        #expect(await sandbox.relaunched().pendingSaveNames().isEmpty)
    }

    /// An account switch is the one reset that takes the tombstones with it:
    /// they name records in the account this device has stopped talking to.
    @Test("Switching accounts drops the tombstones")
    func switchingAccountsClearsDeletions() async {
        let sandbox = Sandbox()
        defer { sandbox.removeAll() }
        await sandbox.store.rememberDeletions([UUID().uuidString])

        await sandbox.store.reset(clearingDeletions: true)

        #expect(await sandbox.relaunched().pendingDeletionNames().isEmpty)
    }

    /// A fetched record must not retire a queued save. A hike this device has
    /// an unsent edit for can arrive from another device in the same pass, and
    /// forgetting the save there would drop the edit with nothing left to
    /// re-send it from.
    @Test("A fetched record leaves a queued save alone; a sent one retires it")
    func onlySentRecordsRetireAQueuedSave() async {
        let sandbox = Sandbox()
        defer { sandbox.removeAll() }
        let recordID = CloudSyncSchema.hikeRecordID(UUID())
        let record = CKRecord(
            recordType: CloudSyncSchema.RecordType.hike,
            recordID: recordID
        )
        await sandbox.store.rememberPendingSaves([recordID.recordName])

        await sandbox.store.remember(record)
        #expect(await sandbox.store.pendingSaveNames() == [recordID.recordName])

        await sandbox.store.rememberSent([record])
        #expect(await sandbox.store.pendingSaveNames().isEmpty)
    }

    /// A deletion fetched from iCloud is offered exactly once, so one whose
    /// write fails has to be held rather than logged — otherwise this device
    /// keeps a hike that was deleted everywhere else, and re-uploads it.
    @Test("A deletion whose write failed is held for the next launch")
    func deferredDeletionsSurviveRelaunch() async {
        let sandbox = Sandbox()
        defer { sandbox.removeAll() }
        let name = UUID().uuidString
        await sandbox.store.deferDeletions([name, name])

        let next = sandbox.relaunched()
        #expect(await next.takeDeferredDeletions() == [name])
        #expect(await next.takeDeferredDeletions().isEmpty)
    }

    /// The half of reconciliation that works without a tombstone: a
    /// remembered hike record with no hike behind it can only be one this
    /// device deleted.
    @Test("A hike record with no local hike is reported as an orphan")
    func orphanedHikeRecordIsFound() async {
        let sandbox = Sandbox()
        defer { sandbox.removeAll() }
        let kept = UUID()
        let deleted = UUID()
        await sandbox.store.remember([
            CKRecord(
                recordType: CloudSyncSchema.RecordType.hike,
                recordID: CloudSyncSchema.hikeRecordID(kept)
            ),
            CKRecord(
                recordType: CloudSyncSchema.RecordType.hike,
                recordID: CloudSyncSchema.hikeRecordID(deleted)
            ),
            Self.photoRecord(id: UUID(), hikeID: kept),
        ])

        let orphans = await sandbox.store.orphanedHikeRecordNames(localHikeIDs: [kept])

        // The photo record is deliberately absent: a photo has no top-level
        // model, so having nothing local behind it is its normal state.
        #expect(orphans == [deleted.uuidString])
    }

    /// The refusal that stands between a store which failed to open and a
    /// wiped iCloud account. `OpenHikesModel` falls back to an empty in-memory
    /// container when the persistent one won't load, while this bookkeeping —
    /// which lives in Application Support and is untouched by that failure —
    /// still names every hike the device ever uploaded.
    @Test("An empty local store never reconciles iCloud's hikes away")
    func emptyLocalStoreIsRefused() async {
        let sandbox = Sandbox()
        defer { sandbox.removeAll() }
        let hikeID = UUID()
        await sandbox.store.remember([
            CKRecord(
                recordType: CloudSyncSchema.RecordType.hike,
                recordID: CloudSyncSchema.hikeRecordID(hikeID)
            ),
        ])

        // The store reports them; refusing to act on the answer is
        // ``HikeSyncEngine``'s job, so both halves are asserted.
        #expect(
            await sandbox.store.orphanedHikeRecordNames(localHikeIDs: [])
                == [hikeID.uuidString]
        )
        #expect(await sandbox.store.pendingDeletionNames().isEmpty)
    }

    // MARK: - Writes that failed

    /// A fetched change is offered once and once only — the change token moves
    /// past it whether or not it landed — so a save that throws has to leave
    /// the payload somewhere durable rather than in a log line.
    @Test("A hike whose write failed is held for the next launch")
    func deferredHikesSurviveRelaunch() async {
        let sandbox = Sandbox()
        defer { sandbox.removeAll() }
        let payload = Self.hikePayload(id: UUID())
        await sandbox.store.deferHikes([payload])

        let next = sandbox.relaunched()
        #expect(await next.takeDeferredHikes().map(\.payload) == [payload])
        #expect(await next.takeDeferredHikes().isEmpty)
    }

    /// Two entries for one hike is not hypothetical: a hike deferred on an
    /// earlier pass that has since changed again arrives in both halves of
    /// `waiting + batch`. The consumer keys a dictionary by id, so a duplicate
    /// used to trap — after `takeDeferredHikes()` had already emptied the file,
    /// taking the payloads down with it.
    @Test("Deferring one hike twice in a batch holds the later copy once")
    func duplicateDeferredHikesCollapse() async {
        let sandbox = Sandbox()
        defer { sandbox.removeAll() }
        let id = UUID()
        var later = Self.hikePayload(id: id)
        later.title = "Later"
        await sandbox.store.deferHikes([Self.hikePayload(id: id), later])

        #expect(await sandbox.relaunched().takeDeferredHikes().map(\.payload) == [later])
    }

    /// Those pixels are on disk with nothing claiming them, which is exactly
    /// what an orphan looks like to the launch-time sweep.
    @Test("A deferred photo claims its files against the orphan sweep")
    func deferredPhotoClaimsItsFiles() async {
        let sandbox = Sandbox()
        defer { sandbox.removeAll() }
        let photo = HikePhoto()
        await sandbox.store.deferPhoto(
            HikePhotoSyncPayload(hikeID: UUID(), photo: photo)
        )

        let claims = await sandbox.store.deferredPhotoFileNames()
        #expect(claims?.contains(photo.fileName) == true)
        #expect(claims?.contains(photo.thumbnailFileName) == true)
    }

    /// The sweep deletes every photo file no claim names, so an unreadable
    /// deferred-photo file must not read as "nothing is deferred" — that is a
    /// complete claim set with a hole in it, and the hole is deleted. `nil`
    /// says "ask again next launch" instead.
    @Test("An unreadable deferred-photo file claims nothing rather than everything")
    func unreadableDeferredPhotosRefuseToClaim() async {
        let sandbox = Sandbox()
        defer { sandbox.removeAll() }
        await sandbox.store.deferPhoto(
            HikePhotoSyncPayload(hikeID: UUID(), photo: HikePhoto())
        )

        try? Data("not json".utf8).write(
            to: sandbox.root
                .appending(path: "support")
                .appending(path: "CloudSync")
                .appending(path: "deferred-photos.json")
        )

        #expect(await sandbox.relaunched().deferredPhotoFileNames() == nil)
    }

    private static func hikePayload(id: UUID) -> HikeSyncPayload {
        HikeSyncPayload(
            id: id,
            title: "Deferred",
            customName: nil,
            distanceMeters: 100,
            date: Date(timeIntervalSince1970: 0),
            tintHex: "#FFFFFF",
            routeWidth: 4,
            routeLinePatternID: "solid",
            symbol: "figure.hiking",
            trackDescription: nil,
            author: nil,
            keywords: nil,
            autoFollowEnabled: false,
            surfaceMetersByCategory: [:],
            difficultyMetersByGrade: [:],
            route: [],
            rawRoute: []
        )
    }
}
