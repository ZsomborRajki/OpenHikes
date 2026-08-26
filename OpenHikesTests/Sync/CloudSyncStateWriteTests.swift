//
//  CloudSyncStateWriteTests.swift
//  OpenHikesTests
//
//  When sync's bookkeeping reaches disk, as opposed to what it says once it
//  is there — which is ``CloudSyncStateStoreTests``' subject.
//
//  The record cache is a whole-file snapshot holding one archived `CKRecord`
//  per hike and per photo, so writing it as each acknowledgement arrived made
//  a first sync quadratic in the size of the library, inside a callback
//  `CKSyncEngine` was awaiting. It is coalesced behind ``flush()`` now, which
//  turns "is it durable?" into a question with two halves: that a burst really
//  does cost one write, and that nothing a crash could ask for is missing from
//  it afterwards.
//
//  Every case builds its own storage root, and every store here takes an
//  explicit window rather than the app's — a suite must not depend on how long
//  a machine took to reach an assertion.
//

import CloudKit
import Foundation
@testable import OpenHikes
import Synchronization
import Testing

@Suite("Cloud sync state writes")
struct CloudSyncStateWriteTests {
    private enum Constants {
        /// Enough acknowledgements that one write each would be unmistakable,
        /// and few enough to stay instant.
        static let burst = 200
        /// Long enough never to elapse inside a case. Anything these tests say
        /// about the window is said by cancelling it or by awaiting it, never
        /// by waiting for it.
        static let neverElapses = Duration.seconds(600)
    }

    /// Every file name a store has written, in order.
    ///
    /// A reference type because the closure that records them escapes into the
    /// store, while the sandbox that reads them back stays here — and a
    /// `Mutex` is neither copyable nor capturable on its own.
    nonisolated private final class WriteLog: Sendable {
        private let names = Mutex([String]())

        func record(_ name: String) {
            names.withLock { recorded in recorded.append(name) }
        }

        func all() -> [String] { names.withLock { $0 } }
    }

    /// A storage root of this case's own, the writes its store made, and the
    /// store itself.
    private struct Sandbox {
        let root: URL
        let store: CloudSyncStateStore
        let writes = WriteLog()

        init(window: Duration? = Constants.neverElapses) {
            let base = URL.temporaryDirectory.appendingPathComponent(
                "CloudSyncStateWriteTests-\(UUID().uuidString)",
                isDirectory: true
            )
            root = base
            let recorder = writes
            store = CloudSyncStateStore(
                storageRoot: Self.support(in: base),
                stagingRoot: base.appendingPathComponent("caches", isDirectory: true),
                coalescingWindow: window
            ) { name in
                recorder.record(name)
            }
        }

        /// What the next launch reads, *without* flushing first — the whole
        /// point here being what a launch finds when nothing flushed.
        func relaunched() -> CloudSyncStateStore {
            CloudSyncStateStore(
                storageRoot: Self.support(in: root),
                stagingRoot: root.appendingPathComponent("caches", isDirectory: true),
                coalescingWindow: nil
            )
        }

        /// The record cache is the only property list here; the index and the
        /// deferred queues are JSON.
        func recordFileWrites() -> Int {
            writes.all().count { $0.hasSuffix(".plist") }
        }

        func fileWrites() -> Int {
            writes.all().count
        }

        private static func support(in root: URL) -> URL {
            root.appendingPathComponent("support", isDirectory: true)
        }

        func removeAll() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private static func hikeRecord(id: UUID = UUID()) -> CKRecord {
        CKRecord(
            recordType: CloudSyncSchema.RecordType.hike,
            recordID: CloudSyncSchema.hikeRecordID(id)
        )
    }

    /// The finding this coalescing exists for: a send carries up to 250
    /// records and a first sync sends thousands, so a rewrite per batch made
    /// the initial upload quadratic in the library's size.
    @Test("A burst of acknowledgements costs one write, not one each")
    func aBurstCostsOneWrite() async {
        let sandbox = Sandbox()
        defer { sandbox.removeAll() }

        for _ in 0..<Constants.burst {
            await sandbox.store.remember(Self.hikeRecord())
        }
        #expect(sandbox.fileWrites() == 0, "nothing is written while the window is open")

        await sandbox.store.flush()

        #expect(sandbox.recordFileWrites() == 1)
        // The index moves with it: `remember` files which hike each record
        // belongs to, and that is the second and last file a burst touches.
        #expect(sandbox.fileWrites() == 2)
    }

    /// The other half of the same claim. Coalescing that dropped the earlier
    /// members of a burst would pass the count above and lose a library.
    @Test("Every record in a coalesced burst is there after the flush")
    func aFlushKeepsEveryRecordInTheBurst() async {
        let sandbox = Sandbox()
        defer { sandbox.removeAll() }
        let hikeIDs = (0..<Constants.burst).map { _ in UUID() }
        let photoID = UUID()

        for id in hikeIDs {
            await sandbox.store.remember(Self.hikeRecord(id: id))
        }
        let photo = CKRecord(
            recordType: CloudSyncSchema.RecordType.photo,
            recordID: CloudSyncSchema.photoRecordID(photoID)
        )
        photo[CloudSyncSchema.PhotoField.hikeID] = hikeIDs[0].uuidString
        await sandbox.store.remember(photo)
        await sandbox.store.flush()

        let next = sandbox.relaunched()
        var found = 0
        for id in hikeIDs
        where await next.lastKnownRecord(id: CloudSyncSchema.hikeRecordID(id)) != nil {
            found += 1
        }
        #expect(found == hikeIDs.count)
        #expect(
            await next.photoRecordNames(ownedBy: hikeIDs[0]) == [photoID.uuidString],
            "the index is coalesced alongside the records and has to arrive with them"
        )
    }

    /// A launch reads files, not memory, so an acknowledgement nothing flushed
    /// is an acknowledgement the next launch has never heard of. Losing one is
    /// recoverable — reconciliation re-uploads and CloudKit merges, since a
    /// record's name is its hike's own `UUID` — which is exactly why this is
    /// the half that may be held back.
    @Test("A remembered record reaches the next launch only once flushed")
    func onlyAFlushIsDurable() async {
        let sandbox = Sandbox()
        defer { sandbox.removeAll() }
        let recordID = CloudSyncSchema.hikeRecordID(UUID())
        await sandbox.store.remember(CKRecord(
            recordType: CloudSyncSchema.RecordType.hike,
            recordID: recordID
        ))

        #expect(await sandbox.relaunched().lastKnownRecord(id: recordID) == nil)

        await sandbox.store.flush()

        #expect(await sandbox.relaunched().lastKnownRecord(id: recordID) != nil)
    }

    /// The backstop for the kill that reaches no flush point at all — the
    /// watchdog, the memory monitor. Awaited rather than slept through, so
    /// what this asserts is that the window writes, not how fast the machine
    /// running it is.
    @Test("The window writes on its own, with nobody flushing")
    func theWindowWritesUnprompted() async {
        let sandbox = Sandbox(window: .zero)
        defer { sandbox.removeAll() }
        let recordID = CloudSyncSchema.hikeRecordID(UUID())

        await sandbox.store.remember(CKRecord(
            recordType: CloudSyncSchema.RecordType.hike,
            recordID: recordID
        ))
        await sandbox.store.pendingWrite()?.value

        #expect(await sandbox.relaunched().lastKnownRecord(id: recordID) != nil)
    }

    /// The carve-out. An edited hike already has a server record, so
    /// reconciliation's "has iCloud ever acknowledged this?" answers yes and
    /// never asks again — this queue is the only memory of an edit made while
    /// the engine was down, and unlike a change tag nothing re-derives it.
    @Test("A save queued while the engine was down is written immediately")
    func aQueuedSaveIsNotCoalesced() async {
        let sandbox = Sandbox()
        defer { sandbox.removeAll() }
        let name = UUID().uuidString

        await sandbox.store.rememberPendingSaves([name])

        #expect(await sandbox.relaunched().pendingSaveNames() == [name])
    }

    /// A tombstone is the other thing no scan of this device could rebuild:
    /// the hike is gone, and iCloud still holds a copy that comes back on the
    /// next fetch.
    @Test("A tombstone is written immediately")
    func aTombstoneIsNotCoalesced() async {
        let sandbox = Sandbox()
        defer { sandbox.removeAll() }
        let name = UUID().uuidString

        await sandbox.store.rememberDeletions([name])

        #expect(await sandbox.relaunched().pendingDeletionNames() == [name])
    }

    /// `reset()` deletes the directory. An armed window that fired afterwards
    /// would put an empty record cache straight back into it — which is a file
    /// the next launch reads, and a directory the user asked to be rid of.
    @Test("Resetting cancels the write the window was holding")
    func resetCancelsTheCoalescedWrite() async {
        let sandbox = Sandbox()
        defer { sandbox.removeAll() }
        await sandbox.store.remember(Self.hikeRecord())
        #expect(await sandbox.store.pendingWrite() != nil, "precondition: a write is armed")

        await sandbox.store.reset()

        #expect(await sandbox.store.pendingWrite() == nil)
        #expect(sandbox.fileWrites() == 0)
    }
}
