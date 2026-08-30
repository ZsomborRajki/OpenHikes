//
//  HikePhotoImportTests.swift
//  OpenHikesTests
//
//  The ordering ``HikePhotoImport``'s header argues for, checked rather than
//  asserted in prose: the app's own copy is written first and is what the hike
//  ends up pointing at, and nothing optional downstream is allowed to be the
//  difference between having the picture and not having it.
//
//  The one case that needs a race rather than a call is the hike going away
//  mid-import. It can, and easily: `attachPickedPhotos` loads up to ten
//  transferables one after another, and the user is free to pop back to the
//  list and swipe the hike off it while that runs. SwiftData detaches a
//  deleted model rather than invalidating it — see `HikeDeletionTests` — so
//  what an unguarded attach produces is not a crash but something quieter and
//  worse: metadata appended to an object nothing will ever persist, and a
//  file on disk with nothing left to claim it. Both halves are checked here.
//
//  Every store here is rooted in a temporary directory, never
//  `HikePhotoStore.shared`: these suites run in parallel with the host app,
//  which writes into the real one.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import SwiftData
import Testing

#if canImport(UIKit)
import UIKit
#endif

@Suite("Hike photo import")
struct HikePhotoImportTests {
    nonisolated private static let sampleSide = 8
    private static let latitude: Double = 47.63
    private static let longitude: Double = 12.86

    /// A genuinely decodable PNG — the store asks ImageIO what the bytes are,
    /// so filler wouldn't get past it.
    nonisolated private static func sampleImageData() -> Data {
        #if canImport(UIKit)
        let size = CGSize(width: sampleSide, height: sampleSide)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            UIColor.systemGreen.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        return image.pngData() ?? Data()
        #else
        return Data()
        #endif
    }

    /// A store with its own directory, removed when the test ends.
    nonisolated private final class Sandbox: Sendable {
        let root: URL
        let store: HikePhotoStore

        init() {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "photo-import-\(UUID().uuidString)",
                    isDirectory: true
                )
            store = HikePhotoStore(storageRoot: root)
        }

        deinit { try? FileManager.default.removeItem(at: root) }
    }

    @Test("adding a photo writes the file first and then attaches it")
    func addWritesFileAndAttaches() async throws {
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

        #expect(hike.photos.map(\.id) == [photo.id])
        #expect(
            FileManager.default.fileExists(
                atPath: sandbox.store.url(for: photo).path
            )
        )
    }

    @Test("the anchor handed in is the one the photo keeps")
    func addKeepsTheAnchor() async throws {
        let sandbox = Sandbox()
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        let coordinate = CLLocationCoordinate2D(
            latitude: Self.latitude,
            longitude: Self.longitude
        )

        let photo = try #require(
            await HikePhotoImport.add(
                Self.sampleImageData(),
                to: hike,
                coordinate: coordinate,
                savesToPhotoLibrary: false,
                store: sandbox.store
            )
        )

        #expect(photo.isAnchored)
        #expect(photo.coordinate?.latitude == coordinate.latitude)
    }

    @Test("bytes that are not an image attach nothing")
    func addRefusesNonImageBytes() async throws {
        let sandbox = Sandbox()
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)

        let photo = await HikePhotoImport.add(
            Data("not a picture".utf8),
            to: hike,
            coordinate: nil,
            savesToPhotoLibrary: false,
            store: sandbox.store
        )

        #expect(photo == nil)
        #expect(hike.photos.isEmpty)
    }

    /// The race the guard exists for. Deleting between the write and the
    /// attach is exactly what a swipe on the hikes list does while an import
    /// is still working through a ten-asset selection.
    @Test("a hike deleted mid-import is not touched, and leaves no file behind")
    func addAbandonsADeletedHike() async throws {
        let sandbox = Sandbox()
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        let data = Self.sampleImageData()

        // Deleted while the bytes are being written: the `await` inside `add`
        // is the window, and an unstructured task on this same actor is what
        // makes the two interleave deterministically rather than by luck —
        // it cannot start until this test suspends, which it does at `value`.
        let importing = Task { @MainActor in
            await HikePhotoImport.add(
                data,
                to: hike,
                coordinate: nil,
                savesToPhotoLibrary: false,
                store: sandbox.store
            )
        }
        context.delete(hike)
        try context.save()
        let stored = await importing.value

        #expect(stored == nil)
        #expect(!hike.isAttached)
        #expect(hike.photos.isEmpty, "a detached model must not be written to")

        // The file the refused attach wrote is erased rather than orphaned.
        // The erase is deliberately fire-and-forget, so this waits on the
        // effect rather than on a returned handle.
        await settleDelegateHop(until: "the orphaned photo file to be erased") {
            Self.fileCount(in: sandbox.store.directory) == 0
        }
        #expect(Self.fileCount(in: sandbox.store.directory) == 0)
    }

    /// Re-picking a photograph the walk already holds. The picker shows no
    /// sign of what has been imported before, so a second selection that
    /// overlaps the first is an ordinary thing for somebody to do — and
    /// without the identifier travelling with the bytes it produced a second
    /// copy of the same picture, in the gallery and on disk.
    ///
    /// The already-attached photo comes back rather than `nil`, because the
    /// asset is in the walk: that is what the caller asked for, and the two
    /// import surfaces treat `nil` as something to report as a failure.
    @Test("an asset already in the hike is not imported twice")
    func addRefusesADuplicateAsset() async throws {
        let sandbox = Sandbox()
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)

        let first = try #require(
            await HikePhotoImport.add(
                Self.sampleImageData(),
                to: hike,
                coordinate: nil,
                savesToPhotoLibrary: false,
                assetLocalIdentifier: "asset-1",
                store: sandbox.store
            )
        )
        let second = await HikePhotoImport.add(
            Self.sampleImageData(),
            to: hike,
            coordinate: nil,
            savesToPhotoLibrary: false,
            assetLocalIdentifier: "asset-1",
            store: sandbox.store
        )

        #expect(second?.id == first.id, "the picture already in the walk")
        #expect(hike.photos.map(\.id) == [first.id])
        #expect(
            Self.fileCount(in: sandbox.store.directory) == 1,
            "and no second copy of it on disk"
        )
    }

    /// The other side of the same guard: a photo with no library asset behind
    /// it — every capture, and a pick the picker gave no identifier for — is
    /// still free to be added as many times as the user takes it.
    @Test("photos with no asset behind them are never treated as duplicates")
    func addAllowsRepeatsWithoutAnAsset() async throws {
        let sandbox = Sandbox()
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)

        for _ in 0..<2 {
            _ = await HikePhotoImport.add(
                Self.sampleImageData(),
                to: hike,
                coordinate: nil,
                savesToPhotoLibrary: false,
                store: sandbox.store
            )
        }

        #expect(hike.photos.count == 2)
    }

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

    /// Called before the hike leaves the store, while it can still be asked
    /// which files are its own — the ordering the deletion path in `MapSheet`
    /// and the recorder's orphan sweep both depend on.
    @Test("discarding a hike's files takes all of them")
    func discardFilesClearsEverything() async throws {
        let sandbox = Sandbox()
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        for _ in 0 ..< 3 {
            _ = await HikePhotoImport.add(
                Self.sampleImageData(),
                to: hike,
                coordinate: nil,
                savesToPhotoLibrary: false,
                store: sandbox.store
            )
        }
        #expect(Self.fileCount(in: sandbox.store.directory) == 3)

        HikePhotoImport.discardFiles(of: hike, store: sandbox.store)

        await settleDelegateHop(until: "every photo file to be erased") {
            Self.fileCount(in: sandbox.store.directory) == 0
        }
        #expect(Self.fileCount(in: sandbox.store.directory) == 0)
    }

    @Test("a hike with no photos discards nothing and doesn't fail")
    func discardFilesToleratesAnEmptyHike() throws {
        let sandbox = Sandbox()
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)

        HikePhotoImport.discardFiles(of: hike, store: sandbox.store)

        #expect(hike.photos.isEmpty)
    }

    /// Files directly under the photo directory, which is the full-size tier;
    /// thumbnails live in a subdirectory and are counted by the store's own
    /// suite.
    ///
    /// Synchronous, and deliberately `FileManager` rather than the store: the
    /// store's methods assert they are off the main thread, while a settle
    /// condition is evaluated on it.
    nonisolated private static func fileCount(in directory: URL) -> Int {
        let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey]
        )
        return contents?.count { url in
            (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        } ?? 0
    }
}
