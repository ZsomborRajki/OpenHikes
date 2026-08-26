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
    ///   copied out of, for a photo found by ``LibraryPhotoMatcher``. Recorded
    ///   so a later scan doesn't offer the same picture twice.
    /// - Parameter matchEvidence: How the coordinate above was arrived at, for
    ///   the same case. `nil` for every photo the app itself placed.
    /// - Returns: The stored photo, or `nil` when the bytes were not an image,
    ///   could not be written, or the hike went away while they were being
    ///   written.
    @MainActor
    @discardableResult static func add(
        _ data: Data,
        to hike: Hike,
        coordinate: CLLocationCoordinate2D?,
        savesToPhotoLibrary: Bool,
        capturedAt: Date = .now,
        assetLocalIdentifier: String? = nil,
        matchEvidence: PhotoMatchEvidence? = nil,
        store: HikePhotoStore = .shared
    ) async -> HikePhoto? {
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
        hike.addPhoto(photo)
        if savesToPhotoLibrary {
            await PhotoLibraryWriter.save(data, fileExtension: photo.pathExtension)
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
        store: HikePhotoStore = .shared
    ) async -> HikePhoto? {
        guard let data = await encoded(frame, in: store) else { return nil }
        return await add(
            data,
            to: hike,
            coordinate: coordinate,
            savesToPhotoLibrary: savesToPhotoLibrary,
            capturedAt: capturedAt,
            store: store
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
