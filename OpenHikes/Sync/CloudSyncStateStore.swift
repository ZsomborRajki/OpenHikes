//
//  CloudSyncStateStore.swift
//  OpenHikes
//
//  The three things sync has to remember across launches, and the one
//  directory it needs scratch space in.
//
//  `CKSyncEngine` keeps a serialized state blob that encodes exactly which
//  server changes this device has already seen. Apple's rule for it is
//  strict: persist it *alongside* the data you fetched in the same pass, or a
//  crash between the two leaves the device believing it has applied changes it
//  hasn't — and there is no second chance, because the server will never send
//  them again.
//
//  Beside it sit the last records the server acknowledged, kept for their
//  change tags. Saving a record built from scratch is a save that claims to
//  know nothing about what is already up there, which is how a conflict stops
//  being a merge and starts being a clobber.
//
//  All of it lives in Application Support next to the tile cache's durable
//  tier, and almost all of it is disposable: deleting the lot costs one full
//  re-download and nothing else, which is exactly what turning sync off does.
//
//  The exception is the tombstones. A deletion is the one local change that
//  cannot be re-derived by looking at this device — the hike is gone, so
//  nothing is left to notice it is missing — and iCloud still holds a copy
//  that would come back on the next fetch. Those survive ``reset()``, and so
//  survive the user switching sync off, deleting a walk, and switching it on
//  again.
//

import CloudKit
import Foundation
import os

/// Scratch files for `CKAsset` uploads.
///
/// A value type over a directory rather than a manager, because the encoding
/// path that needs it is `nonisolated` and synchronous, and `FileManager` is
/// already thread-safe.
nonisolated struct CloudAssetStaging: Sendable {
    /// How long an orphaned staging file is left alone before the launch sweep
    /// takes it. Comfortably longer than any upload, short enough that a
    /// process killed mid-send doesn't leave the file there for a week.
    static let staleAge: TimeInterval = 24 * 3600

    let directory: URL

    /// Writes `data` where CloudKit can read it when the batch is actually
    /// sent, which is later and on another thread. Returns `nil` rather than
    /// throwing: the caller's only recourse is to skip this record, and it has
    /// to be able to do that for the rest of the batch to go.
    func stage(_ data: Data, named name: String) -> URL? {
        let url = directory.appendingPathComponent(name, isDirectory: false)
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
        } catch {
            return nil
        }
        return url
    }

    func discardFiles(prefixed prefix: String) {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return }
        for entry in entries where entry.lastPathComponent.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: entry)
        }
    }

    /// Backstop for the files a terminated send left behind. The same shape of
    /// sweep ``HikePhotoStore/reclaimOrphans(claimedBy:youngerThan:now:)``
    /// runs, and for the same reason: these deletes are fire-and-forget, so
    /// something has to catch what termination interrupted.
    func sweep(olderThan age: TimeInterval = Self.staleAge, now: Date = .now) {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        let cutoff = now.addingTimeInterval(-age)
        for entry in entries {
            let modified = try? entry.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate
            guard let modified, modified < cutoff else { continue }
            try? FileManager.default.removeItem(at: entry)
        }
    }

    func removeAll() {
        try? FileManager.default.removeItem(at: directory)
    }
}
/// A fetched payload this device could not write yet, together with the
/// system fields of the record it arrived in.
///
/// The record travels with it because the change tag is only worth having
/// once the write lands. Remembering it at the moment of deferral would
/// leave ``RecordIndex/hikeRecordNames`` naming a hike with nothing local
/// behind it — which reconciliation reads as a deletion that never went,
/// and answers by deleting the record out of iCloud. Dropping it instead,
/// which is what happened, leaves the write with no tag: ``reconcile()``
/// then reads "no server record" as "never uploaded" and sends back to
/// iCloud the hike it had just downloaded from it.
nonisolated struct Deferred<Payload: Codable & Sendable>: Codable, Sendable {
    var payload: Payload
    var systemFields: Data?
}

/// Everything sync remembers between launches.
///
/// An `actor` rather than a lock-guarded class: every caller is already in an
/// async context (`CKSyncEngineDelegate`'s methods are all `async`), and the
/// work is file I/O that has no business on the main thread anyway.
actor CloudSyncStateStore {
    private static let logger = Logger(subsystem: "OpenHikes", category: "CloudSync")
    private static let directoryName = "CloudSync"
    private static let assetDirectoryName = "CloudSyncAssets"
    private static let stateFileName = "engine-state.json"
    private static let recordsFileName = "server-records.plist"
    private static let deferredPhotosFileName = "deferred-photos.json"
    private static let deferredHikesFileName = "deferred-hikes.json"
    private static let deferredDeletionsFileName = "deferred-deletions.json"
    private static let indexFileName = "record-index.json"
    private static let deletionsFileName = "pending-deletions.json"

    /// How many unsent deletions are kept. Reached only by deleting thousands
    /// of hikes with sync switched off, and a dropped tombstone costs one
    /// resurrected hike rather than anything worse — cheaper than an unbounded
    /// file that nothing ever prunes.
    private static let deletionLimit = 5000

    /// `nonisolated` because it is an immutable `Sendable` value over a
    /// directory: the record encoder needs it synchronously from outside the
    /// actor, and there is nothing here to serialise access to.
    nonisolated let staging: CloudAssetStaging

    private let directory: URL
    private var serverRecords: [String: Data]
    private var deferredPhotos: [Deferred<HikePhotoSyncPayload>]
    private var deferredHikes: [Deferred<HikeSyncPayload>]
    private var deferredDeletions: [String]
    private var index: RecordIndex

    /// False when `deferred-photos.json` existed and could not be read.
    ///
    /// An unreadable file is not an empty one, and the difference decides
    /// whether the launch photo sweep may run: a deferred photo's pixels are
    /// on disk with no `Hike` pointing at them yet, so an under-reported claim
    /// set deletes bytes whose change token the server has already moved past.
    /// This is the same distinction ``OpenHikesModel/photoClaims(fetchingHikes:)``
    /// is built around; it was the one place it had collapsed into `[]`.
    private let deferredPhotosAreComplete: Bool
    /// Records this device wants gone from iCloud but hasn't managed to send.
    ///
    /// Ordered oldest-first so the cap drops the least recent.
    private var pendingDeletions: [String]

    /// What the record names in ``serverRecords`` mean, which their names
    /// alone don't say.
    ///
    /// Both a hike and a photo are named by a bare UUID, so telling them apart
    /// afterwards needs this — and reconciling deletions has to tell them
    /// apart, because a photo record with no top-level local model is normal
    /// while a hike record with no local hike is a deletion that never went.
    private struct RecordIndex: Codable, Sendable {
        /// Photo record name → the hike that owned it when it was last
        /// acknowledged.
        ///
        /// The only way this device can notice a photo the user *removed*. A
        /// removal edits `Hike.photos`, which SwiftData reports as a change to
        /// the hike and to nothing else — the photo simply stops being
        /// mentioned. With no memory of what the hike used to claim there is
        /// nothing to compare against, and the record would sit in iCloud
        /// forever, re-downloading itself onto every other device.
        var photoOwners: [String: String] = [:]
        var hikeRecordNames: Set<String> = []
        /// Records queued for upload while the engine was down.
        ///
        /// `CKSyncEngine` persists its own pending changes, but only once it
        /// exists — and it does not exist during the account round-trip a
        /// launch begins with, which is a window a user can rename a hike in.
        /// Unlike a deletion these need not outlive ``reset()``: a reset
        /// forgets every server record, so reconciliation re-uploads the lot
        /// anyway.
        var pendingSaves: Set<String> = []
    }

    /// - Parameters:
    ///   - storageRoot: Overrides Application Support so a suite gets its own
    ///     state rather than the host app's — the arrangement ``TileCache``
    ///     and ``HikePhotoStore`` both offer.
    ///   - stagingRoot: Overrides Caches, separately, because staged assets are
    ///     re-derivable and so belong somewhere the system may reclaim.
    init(storageRoot: URL? = nil, stagingRoot: URL? = nil) {
        let support = storageRoot ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        let caches = stagingRoot ?? FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        )[0]
        directory = support.appendingPathComponent(Self.directoryName, isDirectory: true)
        staging = CloudAssetStaging(
            directory: caches.appendingPathComponent(
                Self.assetDirectoryName,
                isDirectory: true
            )
        )
        serverRecords = Self.readRecords(
            at: support
                .appendingPathComponent(Self.directoryName, isDirectory: true)
                .appendingPathComponent(Self.recordsFileName, isDirectory: false)
        )
        let readPhotos = Self.readDeferredPhotos(
            at: support
                .appendingPathComponent(Self.directoryName, isDirectory: true)
                .appendingPathComponent(Self.deferredPhotosFileName, isDirectory: false)
        )
        deferredPhotos = readPhotos ?? []
        deferredPhotosAreComplete = readPhotos != nil
        deferredHikes = Self.read(
            [Deferred<HikeSyncPayload>].self,
            at: support
                .appendingPathComponent(Self.directoryName, isDirectory: true)
                .appendingPathComponent(Self.deferredHikesFileName, isDirectory: false)
        ) ?? []
        deferredDeletions = Self.read(
            [String].self,
            at: support
                .appendingPathComponent(Self.directoryName, isDirectory: true)
                .appendingPathComponent(Self.deferredDeletionsFileName, isDirectory: false)
        ) ?? []
        index = Self.read(
            RecordIndex.self,
            at: support
                .appendingPathComponent(Self.directoryName, isDirectory: true)
                .appendingPathComponent(Self.indexFileName, isDirectory: false)
        ) ?? RecordIndex()
        pendingDeletions = Self.read(
            [String].self,
            at: support
                .appendingPathComponent(Self.directoryName, isDirectory: true)
                .appendingPathComponent(Self.deletionsFileName, isDirectory: false)
        ) ?? []
    }

    // MARK: - Engine state

    func loadStateSerialization() -> CKSyncEngine.State.Serialization? {
        guard let data = try? Data(contentsOf: url(Self.stateFileName)) else {
            return nil
        }
        return try? JSONDecoder().decode(
            CKSyncEngine.State.Serialization.self,
            from: data
        )
    }

    func save(stateSerialization: CKSyncEngine.State.Serialization) {
        guard let data = try? JSONEncoder().encode(stateSerialization) else {
            Self.logger.error("Could not encode the sync engine's state.")
            return
        }
        write(data, to: Self.stateFileName)
    }

    // MARK: - Last known server records

    /// The record the server last acknowledged, rebuilt from its system fields
    /// alone — identity, change tag, timestamps. No user data: the fields are
    /// filled from the local model on the way out, which is what makes this a
    /// merge rather than a replay of whatever was up there before.
    func lastKnownRecord(id: CKRecord.ID) -> CKRecord? {
        guard let data = serverRecords[id.recordName] else { return nil }
        return Self.record(fromSystemFields: data)
    }

    /// Which of `ids` the server has never acknowledged.
    ///
    /// The batched form of `lastKnownRecord(id:) == nil`, and the one
    /// reconciliation uses. Asked one id at a time, each question is its own
    /// hop onto this actor — for a 200-hike, 2 000-photo library that is 2 200
    /// sequential suspensions of a caller with nothing else to do, on the
    /// launch path. One call answers the lot, and answers it identically: a
    /// name whose archived bytes no longer parse still counts as never
    /// acknowledged, so a corrupt cache re-uploads rather than going quiet.
    func unacknowledged(_ ids: [CKRecord.ID]) -> [CKRecord.ID] {
        ids.filter { lastKnownRecord(id: $0) == nil }
    }

    /// Rebuilds a record from archived system fields, or `nil`.
    ///
    /// The failure policy is the point. `NSKeyedUnarchiver`'s default is
    /// `.raiseException`, and `CKRecord(coder:)` decodes enough structure to
    /// reach it — so a truncated `server-records.plist`, from a process killed
    /// mid-write or a restored backup, took the app down with an Objective-C
    /// exception Swift cannot catch, on a launch that only needed to forget a
    /// change tag. Answering `nil` turns the same corruption into one
    /// re-upload.
    static func record(fromSystemFields data: Data) -> CKRecord? {
        guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) else {
            return nil
        }
        unarchiver.decodingFailurePolicy = .setErrorAndReturn
        let record = CKRecord(coder: unarchiver)
        unarchiver.finishDecoding()
        guard unarchiver.error == nil else {
            logger.error("Discarded an unreadable archived server record.")
            return nil
        }
        return record
    }

    /// The archived system fields of a record — identity, change tag,
    /// timestamps, and no user data.
    static func systemFields(of record: CKRecord) -> Data {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: archiver)
        archiver.finishEncoding()
        return archiver.encodedData
    }

    func remember(_ record: CKRecord) {
        remember([record])
    }

    /// Remembers records the server has just accepted *from this device*, and
    /// so retires their queued saves.
    ///
    /// Kept apart from ``remember(_:)`` because a fetched record must not
    /// retire anything: a hike this device has an unsent edit for can arrive
    /// from another device in the same pass, and forgetting the queued save
    /// there would drop the edit and leave nothing to re-send.
    func rememberSent(_ records: [CKRecord]) {
        guard !records.isEmpty else { return }
        remember(records)
        forgetPendingSaves(records.map(\.recordID.recordName))
    }

    /// Remembers a whole batch against one write.
    ///
    /// The batch form is the one worth using: a send carries up to 250 records
    /// and a first sync sends thousands, while each write re-encodes the
    /// entire dictionary. Per-record flushing turned an initial upload into
    /// quadratic disk traffic, inside the delegate callbacks the engine is
    /// waiting on.
    func remember(_ records: [CKRecord]) {
        guard !records.isEmpty else { return }
        var touchedIndex = false
        for record in records {
            let name = record.recordID.recordName
            serverRecords[name] = Self.systemFields(of: record)
            switch record.recordType {
            case CloudSyncSchema.RecordType.photo:
                guard let owner = record[CloudSyncSchema.PhotoField.hikeID] as? String
                else { continue }
                index.photoOwners[name] = owner
                touchedIndex = true
            case CloudSyncSchema.RecordType.hike:
                touchedIndex = index.hikeRecordNames.insert(name).inserted || touchedIndex
            default:
                continue
            }
        }
        writeRecords()
        if touchedIndex { writeIndex() }
    }

    /// The photo records iCloud believes belong to this hike.
    ///
    /// Compared against what the hike actually holds to find the removals —
    /// see ``HikeSyncEngine/enqueue(photosByHike:)``.
    func photoRecordNames(ownedBy hikeID: UUID) -> [String] {
        let owner = hikeID.uuidString
        return index.photoOwners.compactMap { name, value in
            value == owner ? name : nil
        }
    }

    /// The same, for several hikes at once.
    ///
    /// ``photoRecordNames(ownedBy:)`` scans every owner entry in the index, so
    /// asking it once per changed hike is quadratic in the library's photo
    /// count — and a first sync changes every hike. One pass builds the whole
    /// answer, in one hop.
    func photoRecordNames(
        ownedByAnyOf hikeIDs: some Sequence<UUID> & Sendable
    ) -> [UUID: [String]] {
        let owners = Set(hikeIDs.map(\.uuidString))
        var names: [UUID: [String]] = [:]
        for (name, owner) in index.photoOwners
        where owners.contains(owner) {
            guard let id = UUID(uuidString: owner) else { continue }
            names[id, default: []].append(name)
        }
        return names
    }

    /// Hike records iCloud still holds that this device no longer has a hike
    /// for.
    ///
    /// The second half of reconciliation, and the half that catches a deletion
    /// whose send never happened — the engine was down, the app was killed
    /// between the two, the account was away. Asking the question this way
    /// round works without a tombstone, because a remembered hike record with
    /// nothing local behind it can only be a hike that was deleted here.
    ///
    /// - Parameter localHikeIDs: Every hike this device holds, *including*
    ///   drafts. Must be complete: an under-reported set here deletes real
    ///   hikes out of iCloud, so the caller's fetch failing has to skip this
    ///   entirely rather than pass an empty set.
    func orphanedHikeRecordNames(localHikeIDs: Set<UUID>) -> [String] {
        let local = Set(localHikeIDs.map(\.uuidString))
        return index.hikeRecordNames.subtracting(local).sorted()
    }

    func forgetRecord(id: CKRecord.ID) {
        forgetRecords(ids: [id])
    }

    func forgetRecords(ids: [CKRecord.ID]) {
        guard !ids.isEmpty else { return }
        var touchedRecords = false
        var touchedIndex = false
        for id in ids {
            touchedRecords = serverRecords.removeValue(forKey: id.recordName) != nil
                || touchedRecords
            touchedIndex = index.photoOwners.removeValue(forKey: id.recordName) != nil
                || touchedIndex
            touchedIndex = index.hikeRecordNames.remove(id.recordName) != nil || touchedIndex
        }
        if touchedRecords { writeRecords() }
        if touchedIndex { writeIndex() }
    }

    /// Deletions fetched from iCloud that could not be written — the
    /// counterpart to ``deferHikes(_:)``, and durable for the same reason.
    func deferDeletions(_ recordNames: [String]) {
        guard !recordNames.isEmpty else { return }
        var known = Set(deferredDeletions)
        for name in recordNames where known.insert(name).inserted {
            deferredDeletions.append(name)
        }
        writeDeferredDeletions()
    }

    func takeDeferredDeletions() -> [String] {
        let names = deferredDeletions
        deferredDeletions = []
        writeDeferredDeletions()
        return names
    }

    // MARK: - Changes waiting to be sent

    func rememberPendingSaves(_ recordNames: [String]) {
        guard !recordNames.isEmpty else { return }
        let before = index.pendingSaves.count
        index.pendingSaves.formUnion(recordNames)
        guard index.pendingSaves.count != before else { return }
        writeIndex()
    }

    func pendingSaveNames() -> [String] { Array(index.pendingSaves) }

    func forgetPendingSaves(_ recordNames: [String]) {
        guard !recordNames.isEmpty else { return }
        let before = index.pendingSaves.count
        index.pendingSaves.subtract(recordNames)
        guard index.pendingSaves.count != before else { return }
        writeIndex()
    }

    // MARK: - Deletions waiting to be sent

    /// Remembers that these records should be gone from iCloud.
    ///
    /// Recorded whether or not sync is running, because the moment to ask a
    /// hike which photos were its own is *before* it is deleted, and that
    /// moment does not come back. A tombstone is discarded when the server
    /// confirms the delete, and it outlives ``reset()`` — a hike deleted with
    /// sync switched off would otherwise be re-downloaded the moment it was
    /// switched on again.
    func rememberDeletions(_ recordNames: [String]) {
        guard !recordNames.isEmpty else { return }
        var known = Set(pendingDeletions)
        let additions = recordNames.filter { known.insert($0).inserted }
        guard !additions.isEmpty else { return }
        pendingDeletions.append(contentsOf: additions)
        if pendingDeletions.count > Self.deletionLimit {
            pendingDeletions.removeFirst(pendingDeletions.count - Self.deletionLimit)
        }
        writeDeletions()
    }

    func pendingDeletionNames() -> [String] { pendingDeletions }

    func forgetDeletions(_ recordNames: [String]) {
        guard !recordNames.isEmpty else { return }
        let sent = Set(recordNames)
        let remaining = pendingDeletions.filter { !sent.contains($0) }
        guard remaining.count != pendingDeletions.count else { return }
        pendingDeletions = remaining
        writeDeletions()
    }

    // MARK: - Photos waiting for their hike

    /// A photo can arrive before the hike it belongs to — CloudKit orders
    /// changes within a zone but says nothing about which of them land in the
    /// same batch. Its pixels are written immediately (CloudKit deletes its own
    /// staged copy moments after the delegate returns), and the metadata waits
    /// here until there is something to attach it to.
    func deferPhoto(_ photo: HikePhotoSyncPayload, from record: CKRecord? = nil) {
        deferredPhotos.removeAll { $0.payload.id == photo.id }
        deferredPhotos.append(
            Deferred(
                payload: photo,
                systemFields: record.map(Self.systemFields(of:))
            )
        )
        writeDeferredPhotos()
    }

    func takeDeferredPhotos() -> [Deferred<HikePhotoSyncPayload>] {
        let photos = deferredPhotos
        deferredPhotos = []
        writeDeferredPhotos()
        return photos
    }

    /// The files a deferred photo's pixels are sitting in, or `nil` when this
    /// launch cannot say.
    ///
    /// Handed to the launch-time orphan sweep. Those bytes are written the
    /// moment they arrive — CloudKit reclaims its own staged copy immediately
    /// — but the metadata that would let a `Hike` claim them is still waiting
    /// for its hike, so to
    /// ``HikePhotoStore/reclaimOrphans(claimedBy:youngerThan:now:)`` they look
    /// exactly like a file nothing points at. Without this the sweep deletes
    /// pixels the server will never send again.
    ///
    /// `nil` rather than an empty set when the file could not be read: the
    /// caller must skip the sweep entirely, for the reason
    /// ``deferredPhotosAreComplete`` gives. That distinction is the whole
    /// point, so `discouraged_optional_collection` is waived here.
    func deferredPhotoFileNames() -> Set<String>? { // swiftlint:disable:this discouraged_optional_collection
        guard deferredPhotosAreComplete else { return nil }
        var names = Set<String>()
        for entry in deferredPhotos {
            names.insert(entry.payload.photo.fileName)
            names.insert(entry.payload.photo.thumbnailFileName)
        }
        return names
    }

    // MARK: - Hikes waiting for a save that failed

    /// Holds hikes whose write to SwiftData failed.
    ///
    /// A fetched change is offered exactly once: the change token moves past
    /// it whether or not it landed, and the server has no reason to mention it
    /// again. So a save that throws — a full disk, a store that won't open —
    /// has to leave the payload somewhere durable rather than a log line, or
    /// the two devices quietly disagree forever.
    /// Duplicate ids among `hikes` collapse to the last one, so the queue holds
    /// at most one entry per hike however the caller assembled its batch —
    /// which is what `takeDeferredHikes()`'s consumers assume when they key a
    /// dictionary by id.
    func deferHikes(_ hikes: [HikeSyncPayload], records: [String: CKRecord] = [:]) {
        guard !hikes.isEmpty else { return }
        let arriving = Set(hikes.map(\.id))
        deferredHikes.removeAll { arriving.contains($0.payload.id) }
        var byID: [UUID: Deferred<HikeSyncPayload>] = [:]
        var order: [UUID] = []
        for payload in hikes {
            if byID[payload.id] == nil { order.append(payload.id) }
            byID[payload.id] = Deferred(
                payload: payload,
                systemFields: records[payload.id.uuidString].map(Self.systemFields(of:))
            )
        }
        deferredHikes.append(contentsOf: order.compactMap { byID[$0] })
        writeDeferredHikes()
    }

    func takeDeferredHikes() -> [Deferred<HikeSyncPayload>] {
        let hikes = deferredHikes
        deferredHikes = []
        writeDeferredHikes()
        return hikes
    }

    // MARK: - Lifecycle

    /// Forgets everything, so the next start is a first start.
    ///
    /// What turning sync off does, and what an account change forces. Never
    /// touches a hike: the local store is the source of truth, and the whole
    /// of what is discarded here is re-derivable from the server.
    /// - Parameter clearingDeletions: Whether the tombstones go too. True
    ///   only for an account *switch*: they name records in the account this
    ///   device has stopped talking to, and the one it has moved to has never
    ///   heard of them.
    func reset(clearingDeletions: Bool = false) {
        if clearingDeletions { pendingDeletions = [] }
        serverRecords = [:]
        deferredPhotos = []
        deferredHikes = []
        deferredDeletions = []
        index = RecordIndex()
        try? FileManager.default.removeItem(at: directory)
        staging.removeAll()
        // Tombstones are the one thing here that isn't re-derivable, so they
        // are written straight back into the directory that was just removed.
        // See ``rememberDeletions(_:)``.
        if !pendingDeletions.isEmpty { writeDeletions() }
    }

    func sweepStagedAssets() {
        staging.sweep()
    }
}

// MARK: - Files

/// Split out of the actor's own body only for length; every member here is
/// part of it.
extension CloudSyncStateStore {

    private func url(_ name: String) -> URL {
        directory.appendingPathComponent(name, isDirectory: false)
    }

    private func write(_ data: Data, to name: String) {
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            try data.write(to: url(name), options: .atomic)
        } catch {
            Self.logger.error(
                "Could not persist \(name, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func writeRecords() {
        // Binary rather than the encoder's default XML: every value here is
        // an archived `CKRecord`, and XML would base64 each one into roughly
        // four bytes per three on a file rewritten once per send.
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let data = try? encoder.encode(serverRecords) else { return }
        write(data, to: Self.recordsFileName)
    }

    private func writeDeferredPhotos() {
        writeJSON(deferredPhotos, to: Self.deferredPhotosFileName)
    }

    private func writeDeferredHikes() {
        writeJSON(deferredHikes, to: Self.deferredHikesFileName)
    }

    private func writeDeferredDeletions() {
        writeJSON(deferredDeletions, to: Self.deferredDeletionsFileName)
    }

    private func writeIndex() {
        writeJSON(index, to: Self.indexFileName)
    }

    private func writeDeletions() {
        writeJSON(pendingDeletions, to: Self.deletionsFileName)
    }

    private func writeJSON(_ value: some Encodable, to name: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        write(data, to: name)
    }

    private static func read<Value: Decodable>(_ type: Value.Type, at url: URL) -> Value? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func readRecords(at url: URL) -> [String: Data] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? PropertyListDecoder().decode([String: Data].self, from: data)) ?? [:]
    }

    /// `nil` when a file is there and cannot be read, which is a different
    /// statement from "nothing is deferred" — see ``deferredPhotosAreComplete``.
    private static func readDeferredPhotos(
        at url: URL
    ) -> [Deferred<HikePhotoSyncPayload>]? { // swiftlint:disable:this discouraged_optional_collection
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            return []
        }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([Deferred<HikePhotoSyncPayload>].self, from: data)
    }
}
