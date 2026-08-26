//
//  HikeSyncApplierTests.swift
//  OpenHikesTests
//
//  The SwiftData boundary: what a fetched change is allowed to do to this
//  device's store, and — the two cases worth the most — what it isn't.
//

import Foundation
@testable import OpenHikes
import SwiftData
import Testing

@MainActor
@Suite("Hike sync applier")
struct HikeSyncApplierTests {
    private enum Constants {
        static let tileKeys = ["osm/14/8000/5000@2"]
        static let remoteTitle = "Renamed on the other phone"
        static let localTitle = "Renamed here"
    }

    private struct Harness {
        let container: ModelContainer
        let applier: HikeSyncApplier

        init() throws {
            container = try Fixture.modelContainer()
            applier = HikeSyncApplier(container: container)
        }

        var context: ModelContext { container.mainContext }

        func hikes() throws -> [Hike] {
            try context.fetch(FetchDescriptor<Hike>())
        }
    }

    private static func payload(
        of hike: Hike,
        titled title: String
    ) throws -> HikeSyncPayload {
        var payload = try #require(HikeSyncPayload(hike: hike))
        payload.title = title
        return payload
    }

    @Test("A hike this device has never seen is inserted")
    func unknownHikeIsInserted() throws {
        let harness = try Harness()
        let source = Fixture.hike(in: harness.context, title: "Ridge Loop")
        let payload = try #require(HikeSyncPayload(hike: source))
        harness.context.delete(source)

        _ = try harness.applier.apply(hikes: [payload], skipping: [])

        let hikes = try harness.hikes()
        #expect(hikes.count == 1)
        #expect(hikes.first?.id == payload.id)
        #expect(hikes.first?.title == "Ridge Loop")
    }

    @Test("A hike this device already holds is updated in place")
    func knownHikeIsUpdated() throws {
        let harness = try Harness()
        let hike = Fixture.hike(in: harness.context, title: "Old")
        let payload = try Self.payload(of: hike, titled: Constants.remoteTitle)

        _ = try harness.applier.apply(hikes: [payload], skipping: [])

        #expect(try harness.hikes().count == 1)
        #expect(hike.title == Constants.remoteTitle)
    }

    /// The conflict policy on this side. A hike with an unsent local change is
    /// one whose user edited it *here*; overwriting it would lose that edit
    /// with nothing shown, whereas leaving it alone lets the pending upload go
    /// out and the two devices settle on it.
    @Test("A hike with a pending local upload is not overwritten")
    func pendingHikeIsSkipped() throws {
        let harness = try Harness()
        let hike = Fixture.hike(in: harness.context, title: Constants.localTitle)
        let payload = try Self.payload(of: hike, titled: Constants.remoteTitle)

        _ = try harness.applier.apply(hikes: [payload], skipping: [hike.id])

        #expect(hike.title == Constants.localTitle)
    }

    /// A draft is being written by the recorder on every fix. A remote copy
    /// would replace a live trace with a stale one.
    @Test("A recording draft is never overwritten by a fetched copy")
    func recordingDraftIsLeftAlone() throws {
        let harness = try Harness()
        let source = Fixture.hike(in: harness.context, title: "Finished")
        let payload = try #require(HikeSyncPayload(hike: source))
        harness.context.delete(source)

        let draft = Fixture.hike(in: harness.context, title: "In progress") { hike in
            hike.isRecording = true
        }
        draft.id = payload.id

        _ = try harness.applier.apply(hikes: [payload], skipping: [])

        #expect(draft.title == "In progress")
    }

    /// The argument for not using SwiftData's CloudKit mirroring, asserted at
    /// the boundary where it would break.
    @Test("A fetched hike cannot claim tiles this device never downloaded")
    func fetchedHikeLeavesTilesAlone() throws {
        let harness = try Harness()
        let hike = Fixture.hike(in: harness.context) { hike in
            hike.autoSavedTileKeys = Constants.tileKeys
        }
        let payload = try Self.payload(of: hike, titled: Constants.remoteTitle)

        _ = try harness.applier.apply(hikes: [payload], skipping: [])

        #expect(hike.autoSavedTileKeys == Constants.tileKeys)
    }

    /// Photo records arrive in whatever batch CloudKit puts them in, which may
    /// not be the one carrying their hike.
    @Test("A photo whose hike hasn't arrived is handed back rather than dropped")
    func orphanPhotoIsReturned() throws {
        let harness = try Harness()
        let payload = HikePhotoSyncPayload(hikeID: UUID(), photo: HikePhoto())

        let unmatched = try harness.applier.apply(photos: [payload])

        #expect(unmatched == [payload])
    }

    @Test("A photo whose hike is present is attached exactly once")
    func photoIsAttachedOnce() throws {
        let harness = try Harness()
        let hike = Fixture.hike(in: harness.context)
        let payload = HikePhotoSyncPayload(hikeID: hike.id, photo: HikePhoto())

        #expect(try harness.applier.apply(photos: [payload]).isEmpty)
        #expect(try harness.applier.apply(photos: [payload]).isEmpty)

        #expect(hike.photos.count == 1)
    }

    @Test("A deletion fetched from iCloud removes the hike")
    func deletionRemovesHike() throws {
        let harness = try Harness()
        let hike = Fixture.hike(in: harness.context)
        let doomed = hike.id

        try harness.applier.applyDeletions(recordNames: [doomed.uuidString])

        #expect(try harness.hikes().isEmpty)
    }

    /// A record name is a bare UUID, so a deletion is looked up as both a hike
    /// and a photo. Exactly one of them matches anything.
    @Test("A photo deletion removes the photo and leaves its hike")
    func deletionRemovesPhotoOnly() throws {
        let harness = try Harness()
        let hike = Fixture.hike(in: harness.context)
        let photo = HikePhoto()
        hike.addPhoto(photo)

        try harness.applier.applyDeletions(recordNames: [photo.id.uuidString])

        #expect(try harness.hikes().count == 1)
        #expect(hike.photos.isEmpty)
    }

    @Test("Drafts are not offered for upload")
    func draftsAreNotSyncable() throws {
        let harness = try Harness()
        let finished = Fixture.hike(in: harness.context, title: "Finished")
        let draft = Fixture.hike(in: harness.context, title: "Draft") { hike in
            hike.isRecording = true
        }
        draft.addPhoto(HikePhoto())

        let identifiers = harness.applier.syncableIdentifiers()

        #expect(identifiers.hikeIDs == [finished.id])
        #expect(identifiers.photoIDs.isEmpty)
    }

    @Test("A hike about to be deleted names its own photos")
    func deletionIdentifiersIncludePhotos() throws {
        let harness = try Harness()
        let hike = Fixture.hike(in: harness.context)
        let photo = HikePhoto()
        hike.addPhoto(photo)

        let identifiers = harness.applier.deletionIdentifiers(of: hike)

        #expect(identifiers.hikeIDs == [hike.id])
        #expect(identifiers.photoIDs == [photo.id])
    }

    /// The loop guard. Without it the save this makes would look to the
    /// coordinator's observer like the user's own edit, and go straight back
    /// up — two devices re-sending each other a hike neither of them touched.
    @Test("The remote-changes flag is down again once the write is finished")
    func remoteFlagIsScoped() throws {
        let harness = try Harness()
        let hike = Fixture.hike(in: harness.context)
        let payload = try Self.payload(of: hike, titled: Constants.remoteTitle)

        #expect(!harness.applier.isApplyingRemoteChanges)
        _ = try harness.applier.apply(hikes: [payload], skipping: [])
        #expect(!harness.applier.isApplyingRemoteChanges)
        #expect(!harness.context.hasChanges)
    }

    /// The other half of the loop guard, and the half that loses data if it is
    /// missing. Nearly every edit in this app is autosave-only, so there is
    /// always a window between the tap and the write; a fetch landing inside
    /// it would fold the user's unsaved edit into the flagged save, where the
    /// observer discards it. A saved model is clean, so nothing would ever
    /// mention that hike again — silently local forever.
    @Test("An unsaved local edit is committed before a fetched change lands")
    func pendingLocalEditIsFlushedFirst() throws {
        let harness = try Harness()
        let edited = Fixture.hike(in: harness.context, title: Constants.localTitle)
        let fetched = Fixture.hike(in: harness.context, title: "Elsewhere")
        try harness.context.save()

        // The user renames one hike; SwiftData hasn't autosaved it yet.
        edited.customName = Constants.localTitle
        #expect(harness.context.hasChanges)

        // Watched the way the coordinator watches: `queue: nil`, so the block
        // runs synchronously inside `save()` and can see the flag's real state
        // rather than whatever it settled on a turn later.
        let witness = SaveWitness()
        let applier = harness.applier
        let editedID = edited.persistentModelID
        let observer = NotificationCenter.default.addObserver(
            forName: ModelContext.didSave,
            object: nil,
            queue: nil
        ) { notification in
            let updated = notification.userInfo?[
                ModelContext.NotificationKey.updatedIdentifiers.rawValue
            ] as? [PersistentIdentifier] ?? []
            MainActor.assumeIsolated {
                guard !applier.isApplyingRemoteChanges else { return }
                if updated.contains(editedID) { witness.sawEditedHike = true }
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        _ = try harness.applier.apply(
            hikes: [Self.payload(of: fetched, titled: Constants.remoteTitle)],
            skipping: []
        )

        #expect(witness.sawEditedHike)
        #expect(edited.customName == Constants.localTitle)
    }

    /// A box the save observer can write to. `@MainActor`, and therefore
    /// `Sendable`, which is what lets the `@Sendable` notification block touch
    /// it at all.
    @MainActor
    private final class SaveWitness {
        var sawEditedHike = false
    }

    /// A name with nothing behind it tells the batch provider to drop the
    /// pending change, so "the fetch failed" and "none of these exist" must
    /// not look alike: one transient failure would otherwise discard every
    /// queued save in the batch, and an edit to an already-synced hike is not
    /// recoverable by reconciling.
    @Test("An empty request is answered, not refused")
    func emptyUploadRequestIsAnswered() throws {
        let harness = try Harness()
        #expect(try harness.applier.uploads(for: ["not-a-uuid"]).isEmpty)
    }

    @Test("Every hike is reported for reconciliation, drafts included")
    func allHikeIDsIncludesDrafts() throws {
        let harness = try Harness()
        let finished = Fixture.hike(in: harness.context)
        let draft = Fixture.hike(in: harness.context)
        draft.isRecording = true

        let ids = try harness.applier.allHikeIDs()

        // Deliberately wider than `syncableIdentifiers()`: this set decides
        // which server records have nothing local behind them, and leaving a
        // draft out would delete its record from iCloud.
        #expect(ids == [finished.id, draft.id])
    }
}
