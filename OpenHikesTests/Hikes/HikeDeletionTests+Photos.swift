//
//  HikeDeletionTests+Photos.swift
//  OpenHikesTests
//
//  The half of a deletion that cannot be rolled back: the photo files.
//
//  `HikePhotoImportTests+Removal` pins this ordering for one photo leaving a
//  hike. These pin it for the hike itself, which is where it used to be the
//  other way round — every whole-hike path erased the pixels first and then
//  asked the store to accept the deletion, so a save that failed, or a
//  process that stopped in that window, left rows claiming files that were
//  already gone.
//
//  The store here is always rooted in a temporary directory, never
//  `HikePhotoStore.shared`: these suites run in parallel with the host app,
//  which writes into the real one. Its fixtures are the photo import suite's,
//  reused rather than re-derived — a fixture rebuilt per file is one that
//  drifts.
//

import Foundation
@testable import OpenHikes
import SwiftData
import Testing

extension HikeDeletionTests {
    private typealias Photos = HikePhotoImportTests

    /// A hike that has been saved once, the way every hike a user can delete
    /// has: `rollback()` restores the store's last committed state, and a hike
    /// that had never reached it would be rolled back out of existence.
    private static func savedHike(
        withPhotos count: Int,
        in context: ModelContext,
        store: HikePhotoStore
    ) async throws -> Hike {
        let hike = Fixture.hike(in: context)
        for _ in 0 ..< count {
            _ = await HikePhotoImport.add(
                Photos.sampleImageData(),
                to: hike,
                coordinate: nil,
                savesToPhotoLibrary: false,
                store: store
            )
        }
        try context.save()
        return hike
    }

    /// The window the durability argument is about, one level out from
    /// `removeSavesBeforeErasing`: the app is killed somewhere between the
    /// hike going and its pictures going, and only one order of the two
    /// survives it.
    @Test("a deleted hike is on disk before its photo files are erased")
    func deletionSavesBeforeErasing() async throws {
        let sandbox = Photos.Sandbox()
        let context = try Fixture.modelContext()
        let hike = try await Self.savedHike(
            withPhotos: 3,
            in: context,
            store: sandbox.store
        )
        #expect(Photos.fileCount(in: sandbox.store.directory) == 3)

        var filesAtSave: Int?
        var filesAfterSave: Int?
        try HikeDeletion.delete([hike], store: sandbox.store) { modelContext in
            filesAtSave = Photos.fileCount(in: sandbox.store.directory)
            try modelContext.save()
            filesAfterSave = Photos.fileCount(in: sandbox.store.directory)
        }

        // What the commit carries, and what it leaves behind: the deletion is
        // the change being written, and every file is still there as it lands.
        // A process killed in that window comes back with pictures no hike
        // claims — orphans the launch sweep reclaims — rather than a hike
        // whose gallery points at pixels nothing can bring back.
        #expect(filesAtSave == 3)
        #expect(filesAfterSave == 3)
        #expect(try context.fetch(FetchDescriptor<Hike>()).isEmpty)
        await settleDelegateHop(until: "the deleted hike's photo files to go") {
            Photos.fileCount(in: sandbox.store.directory) == 0
        }
        #expect(Photos.fileCount(in: sandbox.store.directory) == 0)
    }

    @Test("a deletion that cannot be saved keeps the hike and every file")
    func deletionRestoresWhenTheSaveFails() async throws {
        let sandbox = Photos.Sandbox()
        let context = try Fixture.modelContext()
        let hike = try await Self.savedHike(
            withPhotos: 2,
            in: context,
            store: sandbox.store
        )

        #expect(throws: CocoaError.self) {
            try HikeDeletion.delete([hike], store: sandbox.store) { _ in
                throw CocoaError(.fileWriteUnknown)
            }
        }

        // Every half stays, and stays usable: a hike still in the store whose
        // pictures have been erased is the one state no sweep can repair, and
        // the screen that asked for the deletion is still showing it.
        let remaining = try context.fetch(FetchDescriptor<Hike>())
        #expect(remaining.map(\.id) == [hike.id])
        #expect(hike.isAttached)
        #expect(hike.photos.count == 2)
        await settleDelegateHop()
        #expect(
            Photos.fileCount(in: sandbox.store.directory) == 2,
            "a refused save must not erase anything"
        )
    }

    /// The shape the recorder's orphan sweep has: several hikes, one commit,
    /// and nothing erased until it lands.
    @Test("deleting several hikes at once erases all of their files, after the save")
    func deletingSeveralHikesErasesAllOfTheirFiles() async throws {
        let sandbox = Photos.Sandbox()
        let context = try Fixture.modelContext()
        let first = try await Self.savedHike(
            withPhotos: 2,
            in: context,
            store: sandbox.store
        )
        let second = try await Self.savedHike(
            withPhotos: 1,
            in: context,
            store: sandbox.store
        )

        var filesAtSave: Int?
        try HikeDeletion.delete([first, second], store: sandbox.store) { modelContext in
            filesAtSave = Photos.fileCount(in: sandbox.store.directory)
            try modelContext.save()
        }

        #expect(filesAtSave == 3)
        #expect(try context.fetch(FetchDescriptor<Hike>()).isEmpty)
        await settleDelegateHop(until: "both hikes' photo files to go") {
            Photos.fileCount(in: sandbox.store.directory) == 0
        }
        #expect(Photos.fileCount(in: sandbox.store.directory) == 0)
    }

    @Test("deleting a hike with no photos commits and erases nothing")
    func deletingAHikeWithNoPhotos() throws {
        let sandbox = Photos.Sandbox()
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        try context.save()

        try HikeDeletion.delete([hike], store: sandbox.store)

        #expect(try context.fetch(FetchDescriptor<Hike>()).isEmpty)
    }
}
