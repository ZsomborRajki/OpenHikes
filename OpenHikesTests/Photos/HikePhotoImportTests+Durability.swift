//
//  HikePhotoImportTests+Durability.swift
//  OpenHikesTests
//
//  What "added" has to mean: on disk, in both halves, before anyone is told.
//
//  An add is a file and a row, and the row is the half SwiftData holds. Left
//  to the next autosave, a photo the gallery is already drawing can still be
//  gone at the next launch — its file swept as an orphan, and with the library
//  mirror on, a copy in the user's library as the only thing the import left
//  behind. These check the commit that closes that window: that it lands
//  before the mirror is written, that a store which refuses it takes back both
//  halves, and that a photo reported as added really is in a store opened
//  fresh from disk.
//
//  The mirror image — a removal, which commits before it erases — is in
//  `HikePhotoImportTests+Removal`.
//

import Foundation
@testable import OpenHikes
import SwiftData
import Testing

extension HikePhotoImportTests {
    /// The order the header argues for, from the inside of the commit: the
    /// hike already claims the photo, and the copy nothing can take back has
    /// not been written yet.
    @Test("an added photo's attach is on disk before the library copy is made")
    func addSavesBeforeMirroring() async throws {
        let sandbox = Sandbox()
        let writer = StubPhotoLibraryWriter()
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)

        var photoCountAtSave: Int?
        var mirrorsAtSave: Int?
        let photo = try #require(
            await HikePhotoImport.add(
                Self.sampleImageData(),
                to: hike,
                coordinate: nil,
                savesToPhotoLibrary: true,
                store: sandbox.store,
                libraryWriter: writer,
                save: { modelContext in
                    photoCountAtSave = hike.photos.count
                    mirrorsAtSave = writer.saves.count
                    try modelContext.save()
                }
            )
        )

        #expect(photoCountAtSave == 1, "the attach is what the commit carries")
        #expect(
            mirrorsAtSave == 0,
            "a library copy written first can outlive an import that failed"
        )
        #expect(hike.photos.map(\.id) == [photo.id])
        #expect(writer.saves.count == 1)
    }

    @Test("an attach that cannot be saved keeps neither the row nor the file")
    func addRollsBackWhenTheSaveFails() async throws {
        let sandbox = Sandbox()
        let writer = StubPhotoLibraryWriter()
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)

        let photo = await HikePhotoImport.add(
            Self.sampleImageData(),
            to: hike,
            coordinate: nil,
            savesToPhotoLibrary: true,
            store: sandbox.store,
            libraryWriter: writer,
            save: { _ in throw CocoaError(.fileWriteUnknown) }
        )

        // Nothing of the attempt survives, and the caller is told at once
        // rather than by a photo that quietly vanishes at the next launch.
        #expect(photo == nil)
        #expect(hike.photos.isEmpty)
        await settleDelegateHop(until: "the unsaved photo's file to be erased") {
            Self.fileCount(in: sandbox.store.directory) == 0
        }
        #expect(Self.fileCount(in: sandbox.store.directory) == 0)
        #expect(
            writer.saves.isEmpty,
            "an import OpenHikes did not keep must not leave a library copy"
        )
    }

    /// The claim the return value makes, checked against the disk rather than
    /// against the context that was just written to: every store elsewhere in
    /// this suite is in-memory, where an uncommitted attach is indistinguishable
    /// from a committed one.
    @Test("a photo reported as added is still attached in a fresh context")
    func addSurvivesAReopen() async throws {
        let sandbox = Sandbox()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "photo-import-store-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("OpenHikes.store")
        let localURL = directory.appendingPathComponent("OpenHikesLocal.store")

        let hikeID: UUID
        let photoID: UUID
        do {
            let container = try ModelContainer.openHikes(
                url: storeURL,
                localURL: localURL
            )
            let context = ModelContext(container)
            let hike = Fixture.hike(in: context)
            // Deliberately the only commit in this block: if `add` does not
            // make one of its own, there is nothing on disk to reopen.
            let photo = try #require(
                await HikePhotoImport.add(
                    Self.sampleImageData(),
                    to: hike,
                    coordinate: nil,
                    savesToPhotoLibrary: false,
                    store: sandbox.store
                )
            )
            hikeID = hike.id
            photoID = photo.id
        }

        let container = try ModelContainer.openHikes(
            url: storeURL,
            localURL: localURL
        )
        let context = ModelContext(container)
        let reopened = try #require(
            try context.fetch(
                FetchDescriptor<Hike>(predicate: #Predicate { $0.id == hikeID })
            ).first
        )

        #expect(reopened.photos.map(\.id) == [photoID])
        #expect(
            FileManager.default.fileExists(
                atPath: sandbox.store.url(for: reopened.photos[0]).path
            ),
            "the file the surviving row points at has to be there too"
        )
    }
}
