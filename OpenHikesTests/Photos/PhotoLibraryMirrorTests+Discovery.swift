//
//  PhotoLibraryMirrorTests+Discovery.swift
//  OpenHikesTests
//
//  The mirror's copy, met again on the way back in.
//
//  A capture mirrored into the library lands there as a new asset stamped with
//  the very moment and place the hike holds it at — which is exactly what
//  *Find Photos* looks for. Unless the hike records which asset the mirror
//  made, the scan offers the same photograph back and an import files a second
//  copy of it. These pin the round trip: capture, mirror, scan.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import SwiftData
import Testing

extension PhotoLibraryMirrorTests {
    @Test("a mirrored capture is not offered back to its own hike")
    func mirroredCaptureIsNotOfferedBack() async throws {
        let sandbox = PhotoStoreSandbox()
        let writer = StubPhotoLibraryWriter()
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, route: PhotoDiscoveryFixture.route)
        let coordinate = PhotoDiscoveryFixture.coordinate(atStep: 2)

        let photo = try #require(
            await HikePhotoImport.add(
                PhotoDiscoveryFixture.sampleImageData(),
                to: hike,
                coordinate: coordinate,
                savesToPhotoLibrary: true,
                capturedAt: PhotoDiscoveryFixture.date(atStep: 2),
                store: sandbox.store,
                libraryWriter: writer
            )
        )
        let mirrored = try #require(writer.saves.last?.createdAsset)
        #expect(photo.assetLocalIdentifier == mirrored)
        #expect(hike.photos.map(\.assetLocalIdentifier) == [mirrored])

        // The copy as the library hands it back: same moment, same place.
        let library = StubPhotoLibraryFixture(
            assets: [PhotoDiscoveryFixture.asset(mirrored, atStep: 2, coordinate: coordinate)]
        )
        let controller = PhotoDiscoveryController(reader: library)
        await controller.search(in: hike)

        #expect(controller.phase == .empty, "the only asset is the one the hike already holds")
        #expect(controller.matches.isEmpty)

        // And the picker, which has no list to filter, hands the same asset
        // over directly.
        let picked = await HikePhotoImport.add(
            PhotoDiscoveryFixture.sampleImageData(),
            to: hike,
            coordinate: coordinate,
            savesToPhotoLibrary: false,
            assetLocalIdentifier: mirrored,
            store: sandbox.store,
            libraryWriter: writer
        )
        #expect(picked?.id == photo.id)
        #expect(hike.photos.count == 1)
    }

    /// The order the import guarantees, from the mirror's side: a copy that
    /// never landed in the library takes nothing from the one in the hike —
    /// and leaves it linked to nothing, rather than to an asset that is not
    /// there.
    @Test("a refused mirror keeps the photo and links it to nothing")
    func refusedMirrorKeepsAnUnlinkedPhoto() async throws {
        let sandbox = PhotoStoreSandbox()
        let writer = StubPhotoLibraryWriter(refuses: true)
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)

        let photo = try #require(
            await HikePhotoImport.add(
                PhotoDiscoveryFixture.sampleImageData(),
                to: hike,
                coordinate: nil,
                savesToPhotoLibrary: true,
                capturedAt: Self.capturedAt,
                store: sandbox.store,
                libraryWriter: writer
            )
        )

        #expect(writer.saves.count == 1, "the mirror was attempted")
        #expect(photo.assetLocalIdentifier == nil)
        #expect(hike.photos.map(\.id) == [photo.id])
        #expect(hike.importedPhotoAssetIdentifiers.isEmpty)
    }

    /// The link is committed like the attach, but it is not the photograph:
    /// a store that refuses it costs at most one more offer of the copy, and
    /// must not cost the picture already saved.
    @Test("a link the store refuses keeps the photograph")
    func refusedLinkKeepsThePhoto() async throws {
        let sandbox = PhotoStoreSandbox()
        let writer = StubPhotoLibraryWriter()
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)

        var commits = 0
        let photo = try #require(
            await HikePhotoImport.add(
                PhotoDiscoveryFixture.sampleImageData(),
                to: hike,
                coordinate: nil,
                savesToPhotoLibrary: true,
                capturedAt: Self.capturedAt,
                store: sandbox.store,
                libraryWriter: writer,
                save: { modelContext in
                    commits += 1
                    guard commits == 1 else { throw CocoaError(.fileWriteUnknown) }
                    try modelContext.save()
                }
            )
        )

        #expect(commits == 2, "the attach, then the link")
        #expect(hike.photos.map(\.id) == [photo.id])
        #expect(
            photo.assetLocalIdentifier == writer.saves.last?.createdAsset,
            "still true in memory, for the next autosave to carry"
        )
    }
}
