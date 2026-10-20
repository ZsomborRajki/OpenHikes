//
//  PhotoLibraryMirrorTests+ConcurrentImport.swift
//  OpenHikesTests
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import SwiftData
import Testing

extension PhotoLibraryMirrorTests {
    @Test("a library import that lands before the mirror returns leaves one photograph", arguments: [false, true])
    func importDuringMirroringKeepsOnePhoto(filedUnderPlace: Bool) async throws {
        let sandbox = PhotoStoreSandbox()
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        let place = TrailPlace(
            latitude: PhotoDiscoveryFixture.latitude,
            longitude: PhotoDiscoveryFixture.longitude,
            symbol: .water
        )
        hike.replacePlaces(with: [place], in: context)
        var imported: HikePhoto?
        let writer = StubPhotoLibraryWriter { asset in
            #expect(hike.photos.count == 1)
            #expect(hike.photos.first?.assetLocalIdentifier == nil)
            imported = await HikePhotoImport.add(
                PhotoDiscoveryFixture.sampleImageData(),
                to: hike,
                coordinate: nil,
                savesToPhotoLibrary: false,
                assetLocalIdentifier: asset,
                placeID: filedUnderPlace ? place.id : nil,
                store: sandbox.store
            )
            if let imported {
                CommunityPublisher.markSent([imported.id], on: hike, at: Self.capturedAt)
            }
        }

        let captured = try #require(
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
        let duplicate = try #require(imported)

        #expect(hike.photos.map(\.id) == [captured.id])
        #expect(captured.assetLocalIdentifier == writer.saves.last?.createdAsset)
        #expect(captured.capturedAt == Self.capturedAt)
        #expect(captured.placeID == (filedUnderPlace ? place.id : nil))
        #expect(captured.sentToCommunityAt == Self.capturedAt)
        #expect(FileManager.default.fileExists(atPath: sandbox.store.url(for: captured).path))
        await settleDelegateHop(until: "the duplicate's file to be erased") {
            !FileManager.default.fileExists(atPath: sandbox.store.url(for: duplicate).path)
        }

        let reopened = try #require(try ModelContext(context.container).fetch(FetchDescriptor<Hike>()).first)
        #expect(reopened.photos == [captured], "the commit must include both the link and the duplicate removal")
    }

    @Test("a refused duplicate removal keeps both rows and their files")
    func refusedDuplicateRemovalKeepsBothPhotos() async throws {
        let sandbox = PhotoStoreSandbox()
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        var imported: HikePhoto?
        let writer = StubPhotoLibraryWriter { asset in
            imported = await HikePhotoImport.add(
                PhotoDiscoveryFixture.sampleImageData(),
                to: hike,
                coordinate: nil,
                savesToPhotoLibrary: false,
                assetLocalIdentifier: asset,
                store: sandbox.store
            )
        }
        var commits = 0
        let captured = try #require(
            await HikePhotoImport.add(
                PhotoDiscoveryFixture.sampleImageData(),
                to: hike,
                coordinate: nil,
                savesToPhotoLibrary: true,
                store: sandbox.store,
                libraryWriter: writer,
                save: { modelContext in
                    commits += 1
                    if commits == 2 {
                        #expect(hike.photos.count == 1, "the refused commit is the duplicate's removal")
                        if let imported {
                            #expect(FileManager.default.fileExists(atPath: sandbox.store.url(for: imported).path))
                        }
                        throw CocoaError(.fileWriteUnknown)
                    }
                    try modelContext.save()
                }
            )
        )
        let duplicate = try #require(imported)

        #expect(commits == 2)
        #expect(Set(hike.photos.map(\.id)) == [captured.id, duplicate.id])
        #expect(captured.assetLocalIdentifier == writer.saves.last?.createdAsset)
        try context.save()
        let reopened = try #require(try ModelContext(context.container).fetch(FetchDescriptor<Hike>()).first)
        #expect(Set(reopened.photos.map(\.id)) == [captured.id, duplicate.id])
        for photo in reopened.photos {
            #expect(FileManager.default.fileExists(atPath: sandbox.store.url(for: photo).path))
        }
    }
}
