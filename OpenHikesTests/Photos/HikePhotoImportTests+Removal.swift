//
//  HikePhotoImportTests+Removal.swift
//  OpenHikesTests
//
//  The other direction: taking a photo back out. A whole hike's worth goes
//  the same way, one commit further out, and is checked in
//  `HikeDeletionTests+Photos`.
//
//  Removal is two writes that cannot be made one — the metadata detach, which
//  SwiftData commits, and the file erase, which the store does off the main
//  actor — so the only thing standing between a process killed between them
//  and a gallery row pointing at pixels that no longer exist is their order.
//  These check the order rather than describe it, and check that a detach the
//  context refuses to save takes the erase down with it.
//

import Foundation
@testable import OpenHikes
import SwiftData
import Testing

extension HikePhotoImportTests {
    @Test("removing a photo detaches it and deletes its file")
    func removeDetachesAndErases() async throws {
        let sandbox = Sandbox()
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        let photo = try #require(
            await HikePhotoImport.add(
                Self.sampleImageData(),
                to: hike,
                coordinate: nil,
                savesToPhotoLibrary: false,
                store: sandbox.store
            )
        )

        HikePhotoImport.remove(photo, from: hike, store: sandbox.store)

        // The metadata goes on the main actor, at once.
        #expect(hike.photos.isEmpty)
        // The file goes afterwards, off it.
        await settleDelegateHop(until: "the removed photo's file to be erased") {
            Self.fileCount(in: sandbox.store.directory) == 0
        }
        #expect(Self.fileCount(in: sandbox.store.directory) == 0)
    }

    /// The window the durability argument is about: the app is killed
    /// somewhere between the row going and the pixels going, and only one
    /// order of the two survives it.
    @Test("a removed photo's detach is on disk before its file is erased")
    func removeSavesBeforeErasing() async throws {
        let sandbox = Sandbox()
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        let photo = try #require(
            await HikePhotoImport.add(
                Self.sampleImageData(),
                to: hike,
                coordinate: nil,
                savesToPhotoLibrary: false,
                store: sandbox.store
            )
        )

        var photoCountAtSave: Int?
        var filesAfterSave: Int?
        HikePhotoImport.remove(photo, from: hike, store: sandbox.store) { modelContext in
            photoCountAtSave = hike.photos.count
            try modelContext.save()
            filesAfterSave = Self.fileCount(in: sandbox.store.directory)
        }

        // What the commit carries, and what it leaves behind: the detach is
        // the change being written, and the file is still there as it lands.
        // A process killed in that window comes back with a photo the hike no
        // longer claims — an orphan the launch sweep reclaims — rather than a
        // row pointing at pixels nothing can bring back.
        #expect(photoCountAtSave == 0)
        #expect(filesAfterSave == 1)
        await settleDelegateHop(until: "the removed photo's file to be erased") {
            Self.fileCount(in: sandbox.store.directory) == 0
        }
        #expect(Self.fileCount(in: sandbox.store.directory) == 0)
    }

    @Test("a removal that cannot be saved keeps the photo and its file")
    func removeRestoresWhenTheSaveFails() async throws {
        let sandbox = Sandbox()
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        let photo = try #require(
            await HikePhotoImport.add(
                Self.sampleImageData(),
                to: hike,
                coordinate: nil,
                savesToPhotoLibrary: false,
                store: sandbox.store
            )
        )

        HikePhotoImport.remove(photo, from: hike, store: sandbox.store) { _ in
            throw CocoaError(.fileWriteUnknown)
        }

        // Both halves stay. A gallery that had forgotten the photo while its
        // file survived would show it again at the next launch, having undone
        // the removal by itself and said nothing about it.
        #expect(hike.photos.map(\.id) == [photo.id])
        await settleDelegateHop()
        #expect(
            Self.fileCount(in: sandbox.store.directory) == 1,
            "a refused save must not erase anything"
        )
    }

    @Test("removing a photo that isn't attached leaves the rest alone")
    func removeIgnoresAStranger() async throws {
        let sandbox = Sandbox()
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        let kept = try #require(
            await HikePhotoImport.add(
                Self.sampleImageData(),
                to: hike,
                coordinate: nil,
                savesToPhotoLibrary: false,
                store: sandbox.store
            )
        )

        HikePhotoImport.remove(HikePhoto(), from: hike, store: sandbox.store)

        #expect(hike.photos.map(\.id) == [kept.id])
        #expect(
            FileManager.default.fileExists(
                atPath: sandbox.store.url(for: kept).path
            )
        )
    }
}
