//
//  HikePhotoStoreTests.swift
//  OpenHikesTests
//
//  Exercises the disk side of the photo feature against a store rooted in a
//  temporary directory, never `HikePhotoStore.shared` — the singleton writes
//  into the host app's Application Support, and these suites run in parallel
//  with everything else the app does at launch. Same arrangement, and same
//  reason, as ``TileSandbox``.
//
//  Everything here hops off the main thread through ``offMain(_:)``: the store
//  asserts it isn't on main, exactly as the tile pipeline does.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import Testing

#if canImport(UIKit)
import UIKit
#endif

/// A store with its own directory, cleaned up when the test that made it ends.
///
/// A class rather than a value type so `deinit` can do the cleanup: Swift
/// Testing gives a suite instance per test, so the sandbox's lifetime is
/// already exactly the test's.
nonisolated private final class PhotoSandbox: Sendable {
    let root: URL
    let store: HikePhotoStore

    init() {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("photo-sandbox-\(UUID().uuidString)", isDirectory: true)
        store = HikePhotoStore(storageRoot: root)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }
}

@Suite("Hike photo store")
struct HikePhotoStoreTests {
    nonisolated private static let sampleSide = 8
    private static let anchorLatitude: Double = 47.63
    private static let anchorLongitude: Double = 12.86

    /// A small but genuinely decodable PNG. Filler bytes wouldn't do: the
    /// store asks ImageIO what the data actually is, which is the whole point
    /// of ``ImageDataFormat``.
    nonisolated private static func sampleImageData() -> Data {
        #if canImport(UIKit)
        let size = CGSize(width: sampleSide, height: sampleSide)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        return image.pngData() ?? Data()
        #else
        return Data()
        #endif
    }

    @Test("storing image bytes writes a file and reports the real format")
    func storeWritesFile() async throws {
        let sandbox = PhotoSandbox()
        let data = Self.sampleImageData()
        try #require(!data.isEmpty)

        let photo = try #require(
            await offMain { sandbox.store.store(data, capturedAt: .now, coordinate: nil) }
        )

        // PNG in, PNG out: the extension comes from the bytes, not from
        // whatever handed them over.
        #expect(photo.pathExtension == "png")
        #expect(photo.isAnchored == false)
        let url = sandbox.store.url(for: photo)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("bytes that are not an image are refused rather than stored")
    func storeRefusesNonImageData() async {
        let sandbox = PhotoSandbox()
        let data = Data("not a picture".utf8)

        let photo = await offMain {
            sandbox.store.store(data, capturedAt: .now, coordinate: nil)
        }

        #expect(photo == nil)
    }

    @Test("a coordinate handed in comes back on the photo")
    func storeKeepsCoordinate() async throws {
        let sandbox = PhotoSandbox()
        let coordinate = CLLocationCoordinate2D(
            latitude: Self.anchorLatitude,
            longitude: Self.anchorLongitude
        )

        let photo = try #require(
            await offMain {
                sandbox.store.store(
                    Self.sampleImageData(),
                    capturedAt: .now,
                    coordinate: coordinate
                )
            }
        )

        #expect(photo.isAnchored)
        #expect(photo.coordinate?.latitude == coordinate.latitude)
        #expect(photo.coordinate?.longitude == coordinate.longitude)
    }

    @Test("a thumbnail is rendered once and read back from disk after that")
    func thumbnailIsPersisted() async throws {
        let sandbox = PhotoSandbox()
        let photo = try #require(
            await offMain {
                sandbox.store.store(
                    Self.sampleImageData(),
                    capturedAt: .now,
                    coordinate: nil
                )
            }
        )

        let first = await offMain { sandbox.store.thumbnail(for: photo) }
        #expect(first != nil)

        // The measure that matters: the thumbnail now costs disk of its own,
        // which is what stops the strip re-downsampling a capture per
        // appearance.
        let bytes = await offMain { sandbox.store.byteCount(of: [photo]) }
        let fileBytes = try Data(contentsOf: sandbox.store.url(for: photo)).count
        #expect(bytes > Int64(fileBytes))

        let second = await offMain { sandbox.store.thumbnail(for: photo) }
        #expect(second != nil)
    }

    @Test("the viewer's image decodes from the stored file")
    func displayImageDecodes() async throws {
        let sandbox = PhotoSandbox()
        let photo = try #require(
            await offMain {
                sandbox.store.store(
                    Self.sampleImageData(),
                    capturedAt: .now,
                    coordinate: nil
                )
            }
        )

        let image = await offMain { sandbox.store.displayImage(for: photo) }

        #expect(image != nil)
    }

    @Test("removing a photo takes its file and its thumbnail with it")
    func removeDeletesEverything() async throws {
        let sandbox = PhotoSandbox()
        let photo = try #require(
            await offMain {
                sandbox.store.store(
                    Self.sampleImageData(),
                    capturedAt: .now,
                    coordinate: nil
                )
            }
        )
        _ = await offMain { sandbox.store.thumbnail(for: photo) }

        await offMain { sandbox.store.remove([HikePhotoStore.PhotoFiles(photo)]) }

        #expect(!FileManager.default.fileExists(atPath: sandbox.store.url(for: photo).path))
        let bytes = await offMain { sandbox.store.byteCount(of: [photo]) }
        #expect(bytes == 0)
    }

    @Test("removing a photo whose file is already gone is not an error")
    func removeToleratesMissingFiles() async {
        let sandbox = PhotoSandbox()
        // What a partly-failed import leaves behind: metadata with nothing
        // under it.
        let orphan = HikePhoto()

        await offMain { sandbox.store.remove([HikePhotoStore.PhotoFiles(orphan)]) }

        #expect(await offMain { sandbox.store.byteCount(of: [orphan]) } == 0)
    }

    @Test("a missing file decodes to nothing rather than crashing the gallery")
    func missingFileDecodesToNil() async {
        let sandbox = PhotoSandbox()
        let orphan = HikePhoto()

        #expect(await offMain { sandbox.store.thumbnail(for: orphan) } == nil)
        #expect(await offMain { sandbox.store.displayImage(for: orphan) } == nil)
        #expect(await offMain { sandbox.store.imageData(for: orphan) } == nil)
    }

    /// Two roots stand in for two devices: the row travels, the file does not.
    @Test("two stores with different roots don't see each other's photos")
    func storesAreIsolatedByRoot() async throws {
        let first = PhotoSandbox()
        let second = PhotoSandbox()
        let photo = try #require(
            await offMain {
                first.store.store(
                    Self.sampleImageData(),
                    capturedAt: .now,
                    coordinate: nil
                )
            }
        )

        #expect(await offMain { second.store.displayImage(for: photo) } == nil)
        #expect(await offMain { !second.store.hasImage(for: photo) })
        #expect(await offMain { first.store.hasImage(for: photo) })
    }

    /// The question everything above the store asks to tell "this device never
    /// had it" apart from "this device cannot read it" — the two empty answers
    /// a decode gives back as one `nil`.
    @Test("a photo's pixels are reported present exactly while its file is there")
    func hasImageFollowsTheFile() async throws {
        let sandbox = PhotoSandbox()
        let photo = try #require(
            await offMain {
                sandbox.store.store(
                    Self.sampleImageData(),
                    capturedAt: .now,
                    coordinate: nil
                )
            }
        )
        #expect(await offMain { sandbox.store.hasImage(for: photo) })

        await offMain { sandbox.store.remove([HikePhotoStore.PhotoFiles(photo)]) }

        #expect(await offMain { !sandbox.store.hasImage(for: photo) })
        // A row that was never written here at all — a photo taken on another
        // device, arriving as metadata by itself.
        #expect(await offMain { !sandbox.store.hasImage(for: HikePhoto()) })
    }

    // MARK: - Reclaiming orphans

    @Test("a sweep deletes the files no photo claims and keeps the ones it does")
    func reclaimRemovesOnlyUnclaimedFiles() async throws {
        let sandbox = PhotoSandbox()
        let kept = try #require(
            await offMain {
                sandbox.store.store(
                    Self.sampleImageData(),
                    capturedAt: .now,
                    coordinate: nil
                )
            }
        )
        let orphaned = try #require(
            await offMain {
                sandbox.store.store(
                    Self.sampleImageData(),
                    capturedAt: .now,
                    coordinate: nil
                )
            }
        )
        // Both have thumbnails on disk, so the sweep has two tiers to get right.
        _ = await offMain { sandbox.store.thumbnail(for: kept) }
        _ = await offMain { sandbox.store.thumbnail(for: orphaned) }

        let removed = await offMain {
            sandbox.store.reclaimOrphans(
                claimedBy: [kept.fileName, kept.thumbnailFileName],
                now: .now.addingTimeInterval(Self.pastTheGracePeriod)
            )
        }

        #expect(removed == 2, "the orphan's full-size file and its thumbnail")
        #expect(await offMain { sandbox.store.byteCount(of: [kept]) } > 0)
        #expect(await offMain { sandbox.store.byteCount(of: [orphaned]) } == 0)
    }

    /// The sweep runs while imports can be in flight, and a photo is on disk
    /// before it is attached — so for a moment a perfectly good picture looks
    /// exactly like an orphan. Deleting it would be the sweep causing the very
    /// loss it exists to prevent.
    @Test("a file too young to have been attached yet is left alone")
    func reclaimSparesFilesInsideTheGracePeriod() async throws {
        let sandbox = PhotoSandbox()
        let inFlight = try #require(
            await offMain {
                sandbox.store.store(
                    Self.sampleImageData(),
                    capturedAt: .now,
                    coordinate: nil
                )
            }
        )

        let removed = await offMain {
            sandbox.store.reclaimOrphans(claimedBy: [])
        }

        #expect(removed == 0)
        #expect(await offMain { sandbox.store.byteCount(of: [inFlight]) } > 0)
    }

    @Test("a sweep of a store that has never written anything is not an error")
    func reclaimToleratesAnAbsentDirectory() async {
        let sandbox = PhotoSandbox()

        #expect(await offMain { sandbox.store.reclaimOrphans(claimedBy: []) } == 0)
    }

    /// Far enough past a file's write that the grace period no longer covers
    /// it, without the test having to wait for real time to pass.
    nonisolated private static let pastTheGracePeriod: TimeInterval = 3600
}
