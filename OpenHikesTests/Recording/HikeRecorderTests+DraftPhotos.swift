//
//  HikeRecorderTests+DraftPhotos.swift
//  OpenHikesTests
//
//  A discarded recording draft is a hike with pictures in it: the camera
//  attaches them to the draft while the walk is on, so the two paths that
//  throw a draft away — Discard, and the orphan sweep at the next launch —
//  are deleting photo files as surely as a swipe on the list is.
//
//  They go through `HikeDeletion` for that reason, and these check the half of
//  it the recorder owns: the sweep's own commit is what releases the erase,
//  and a commit it is refused releases nothing.
//

import Foundation
@testable import OpenHikes
import OpenHikesShared
import SwiftData
import Testing

extension HikeRecorderTests {
    private typealias Photos = HikePhotoImportTests

    /// An abandoned draft with one picture attached, saved, exactly as the
    /// launch after a crash finds it.
    private func orphanedDraft(
        in store: HikePhotoStore
    ) async throws -> UUID {
        let orphan = Hike(
            title: "Interrupted Hike",
            distanceMeters: 0,
            isRecording: true
        )
        context.insert(orphan)
        try context.save()
        _ = await HikePhotoImport.add(
            Photos.sampleImageData(),
            to: orphan,
            coordinate: nil,
            savesToPhotoLibrary: false,
            store: store
        )
        try context.save()
        return orphan.id
    }

    @Test("an orphaned draft's deletion is on disk before its photos are erased")
    func orphanSweepSavesBeforeErasing() async throws {
        let sandbox = Photos.Sandbox()
        _ = try await orphanedDraft(in: sandbox.store)
        #expect(Photos.fileCount(in: sandbox.store.directory) == 1)

        var filesAtSave: Int?
        let hikeRecorder = makeRecorder(
            saveModelContext: { modelContext in
                filesAtSave = Photos.fileCount(in: sandbox.store.directory)
                try modelContext.save()
            },
            photoStore: sandbox.store
        )

        try hikeRecorder.deleteOrphanedRecordingHikes()

        #expect(filesAtSave == 1, "the sweep's commit must carry the files still on disk")
        #expect(try context.fetch(FetchDescriptor<Hike>()).isEmpty)
        await settleDelegateHop(until: "the orphaned draft's photo file to go") {
            Photos.fileCount(in: sandbox.store.directory) == 0
        }
        #expect(Photos.fileCount(in: sandbox.store.directory) == 0)
    }

    @Test("a sweep whose save is refused keeps the draft and its photos")
    func orphanSweepKeepsEverythingWhenTheSaveFails() async throws {
        let sandbox = Photos.Sandbox()
        let draftID = try await orphanedDraft(in: sandbox.store)
        let hikeRecorder = makeRecorder(
            saveModelContext: { _ in throw InjectedPersistenceError() },
            photoStore: sandbox.store
        )

        #expect(throws: RecordingFailure.self) {
            try hikeRecorder.deleteOrphanedRecordingHikes()
        }

        // The draft is still there to be swept at the next launch, and its
        // picture is still under it. Erasing first would have made the retry
        // meaningless: the row would come back with nothing behind it.
        let remaining = try context.fetch(FetchDescriptor<Hike>())
        #expect(remaining.map(\.id) == [draftID])
        await settleDelegateHop()
        #expect(
            Photos.fileCount(in: sandbox.store.directory) == 1,
            "a refused save must not erase anything"
        )
    }

    @Test("discarding a recording draft erases its photos only after the commit")
    func discardSavesBeforeErasing() async throws {
        let sandbox = Photos.Sandbox()
        let draftID = try await orphanedDraft(in: sandbox.store)

        var filesAtSave: Int?
        let hikeRecorder = makeRecorder(
            saveModelContext: { modelContext in
                filesAtSave = Photos.fileCount(in: sandbox.store.directory)
                try modelContext.save()
            },
            photoStore: sandbox.store
        )

        try hikeRecorder.deleteRecordingHike(sessionID: draftID)

        #expect(filesAtSave == 1)
        #expect(try context.fetch(FetchDescriptor<Hike>()).isEmpty)
        await settleDelegateHop(until: "the discarded draft's photo file to go") {
            Photos.fileCount(in: sandbox.store.directory) == 0
        }
        #expect(Photos.fileCount(in: sandbox.store.directory) == 0)
    }
}
