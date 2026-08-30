//
//  HikePhotoImport.swift
//  OpenHikes
//
//  Adding a photo to a hike, and taking one away again.
//
//  The order matters and is the same on both paths: the app's own copy is
//  written first, and only then is anything else attempted. A photo library
//  save that is refused, a hike whose route turns out to have no coordinate to
//  pin to — neither is allowed to be the difference between having the picture
//  and not having it.
//
//  Deleting is the mirror image: the metadata goes on the main actor, where
//  the `@Model` lives, and the files go afterwards on the concurrent executor.
//  A file left behind by a failed delete is wasted space; a `Hike` still
//  claiming a file that is gone is a broken gallery tile.
//

import CoreLocation
import Foundation
import SwiftData

nonisolated enum HikePhotoImport {
    /// Stores image bytes and attaches them to `hike`.
    ///
    /// - Parameter savesToPhotoLibrary: The user's opt-in — see
    ///   ``SettingsKey/savePhotosToLibrary``. Off by default, and the reason
    ///   the library permission prompt appears here rather than at launch.
    /// - Parameter assetLocalIdentifier: The library asset these bytes were
    ///   copied out of, for a photo that came out of the user's photo library
    ///   — found by ``LibraryPhotoMatcher``, or handed over by the picker.
    ///   Recorded so the same picture cannot be attached to one walk twice,
    ///   and checked here before anything is written.
    /// - Parameter matchEvidence: How the coordinate above was arrived at, for
    ///   the same case. `nil` for every photo the app itself placed.
    /// - Parameter libraryWriter: The seam the mirrored copy goes through, so
    ///   a test can watch what it was handed without a photo library to write
    ///   into.
    /// - Returns: The stored photo, or `nil` when the bytes were not an image,
    ///   could not be written, or the hike went away while they were being
    ///   written. A photo this hike already holds for `assetLocalIdentifier`
    ///   comes back as-is: the asset is in the walk, which is what the caller
    ///   asked for, so this is a success and not a failure to report.
    @MainActor
    @discardableResult static func add(
        _ data: Data,
        to hike: Hike,
        coordinate: CLLocationCoordinate2D?,
        savesToPhotoLibrary: Bool,
        capturedAt: Date = .now,
        assetLocalIdentifier: String? = nil,
        matchEvidence: PhotoMatchEvidence? = nil,
        store: HikePhotoStore = .shared,
        libraryWriter: any PhotoLibraryWriting = PhotoLibraryWriter()
    ) async -> HikePhoto? {
        // Asked before the bytes are written rather than after, so a repeat
        // costs no file and no decode. The scan filters its own offers by the
        // same identifiers, but the picker cannot: it hands over whatever the
        // user tapped, and a selection that overlaps an earlier one is an
        // ordinary thing to do — the picker shows no sign of what this app
        // already has.
        if let assetLocalIdentifier,
           let existing = hike.importedPhoto(forAsset: assetLocalIdentifier) {
            return existing
        }
        guard let photo = await stored(
            data,
            capturedAt: capturedAt,
            coordinate: coordinate,
            assetLocalIdentifier: assetLocalIdentifier,
            matchEvidence: matchEvidence,
            in: store
        ) else { return nil }
        // The write above is an `await`, and an import can spend seconds in it
        // — long enough for the user to pop back to the list and swipe the
        // hike away. Writing to a hike that is no longer in the store succeeds
        // and persists nothing, so the file just written would have nothing
        // left to claim it; it goes with the attempt.
        guard hike.isAttached else {
            discardFiles([photo], from: store)
            return nil
        }
        // And long enough for the other library surface to have attached this
        // very asset in the meantime — the scan and the picker are two ways to
        // reach the same photograph, and only a check on this side of the
        // suspension can see the one that got there first.
        if let assetLocalIdentifier,
           let existing = hike.importedPhoto(forAsset: assetLocalIdentifier) {
            discardFiles([photo], from: store)
            return existing
        }
        hike.addPhoto(photo)
        if savesToPhotoLibrary {
            // Read back off the stored photo rather than from the arguments,
            // so the copy in the user's library and the copy in the app carry
            // the same claims about when and where it was taken. `coordinate`
            // is genuinely absent for a photo the app could not place, and an
            // absent location is written as an absent one.
            await libraryWriter.save(
                data,
                fileExtension: photo.pathExtension,
                capturedAt: photo.capturedAt,
                coordinate: photo.coordinate
            )
        }
        return photo
    }

    /// Encodes a frame straight off the camera, then stores it as above.
    @MainActor
    @discardableResult static func add(
        captured frame: CapturedFrame,
        to hike: Hike,
        coordinate: CLLocationCoordinate2D?,
        savesToPhotoLibrary: Bool,
        capturedAt: Date = .now,
        store: HikePhotoStore = .shared,
        libraryWriter: any PhotoLibraryWriting = PhotoLibraryWriter()
    ) async -> HikePhoto? {
        guard let data = await encoded(frame, in: store) else { return nil }
        return await add(
            data,
            to: hike,
            coordinate: coordinate,
            savesToPhotoLibrary: savesToPhotoLibrary,
            capturedAt: capturedAt,
            store: store,
            libraryWriter: libraryWriter
        )
    }

    /// Detaches one photo and deletes its files.
    @MainActor
    static func remove(
        _ photo: HikePhoto,
        from hike: Hike,
        store: HikePhotoStore = .shared
    ) {
        guard let removed = hike.removePhoto(id: photo.id) else { return }
        discardFiles([removed], from: store)
    }

    /// Deletes every file behind a hike that is being deleted.
    ///
    /// Called *before* the hike leaves the store, while its metadata can still
    /// be read — the same ordering the tile deletion in ``MapSheet`` uses, and
    /// for the same reason: a detached `@Model` has nothing left to enumerate.
    @MainActor
    static func discardFiles(of hike: Hike, store: HikePhotoStore = .shared) {
        discardFiles(hike.photos, from: store)
    }

    /// Fire-and-forget: a delete that fails costs disk space and nothing else,
    /// and there is no screen where waiting for it would tell the user
    /// anything.
    @MainActor
    static func discardFiles(
        _ photos: [HikePhoto],
        from store: HikePhotoStore = .shared
    ) {
        guard !photos.isEmpty else { return }
        Task(priority: .utility) { await erase(photos, in: store) }
    }

    // MARK: - Off the main thread

    @concurrent
    private static func stored(
        _ data: Data,
        capturedAt: Date,
        coordinate: CLLocationCoordinate2D?,
        assetLocalIdentifier: String?,
        matchEvidence: PhotoMatchEvidence?,
        in store: HikePhotoStore
    ) async -> HikePhoto? {
        store.store(
            data,
            capturedAt: capturedAt,
            coordinate: coordinate,
            assetLocalIdentifier: assetLocalIdentifier,
            matchEvidence: matchEvidence
        )
    }

    @concurrent
    private static func encoded(
        _ frame: CapturedFrame,
        in store: HikePhotoStore
    ) async -> Data? {
        store.encode(frame.image)
    }

    @concurrent
    private static func erase(
        _ photos: [HikePhoto],
        in store: HikePhotoStore
    ) async {
        store.remove(photos)
    }
}
