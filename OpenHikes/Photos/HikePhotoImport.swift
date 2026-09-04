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
//  Which is why the detach is *saved* before the files go, rather than left to
//  the next autosave. The two halves cannot be made simultaneous, so the only
//  choice is which way an interruption between them falls: a row that is gone
//  from disk leaves an unclaimed file, which
//  ``OpenHikesModel/reclaimOrphanedPhotos(in:store:)`` sweeps at the next
//  launch, while erasing first would leave the row back in the hike after a
//  kill — pointing at pixels that no sweep can bring back.
//

import CoreLocation
import Foundation
import os
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
    ///
    /// - Parameter capturedAt: Only the fallback. The frame's own shutter time
    ///   wins whenever the camera reported one, because it is the truthful
    ///   answer and this is not: a capture reaches here when the user accepts
    ///   the shot, which is after an unbounded look at it in the review
    ///   screen, and ``HikePhoto/capturedAt`` is what places the picture on
    ///   the elevation profile and orders the gallery. See
    ///   ``CameraCaptureMetadata``.
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
            capturedAt: frame.capturedAt ?? capturedAt,
            store: store,
            libraryWriter: libraryWriter
        )
    }

    /// Detaches one photo, persists the detach, and only then deletes its
    /// files.
    ///
    /// The save is what makes this durable rather than merely started — see
    /// this file's header for why the order is this way round and not the
    /// other.
    ///
    /// A save that fails puts the photo back. The row and the file are the two
    /// halves of one picture, and a gallery that has forgotten a photo whose
    /// file is still on disk is a photo that returns at the next launch: the
    /// removal the user asked for would have undone itself, quietly, later.
    /// Leaving it in place is the same answer given at once.
    ///
    /// - Parameter save: The seam the commit goes through, so a test can watch
    ///   what is on disk at the moment the detach lands, or refuse it.
    @MainActor
    static func remove(
        _ photo: HikePhoto,
        from hike: Hike,
        store: HikePhotoStore = .shared,
        save: (ModelContext) throws -> Void = { try $0.save() }
    ) {
        guard let removed = hike.removePhoto(id: photo.id) else { return }
        guard persisted(hike, save) else {
            hike.addPhoto(removed)
            return
        }
        discardFiles([removed], from: store)
    }

    /// Commits the store `hike` lives in, and reports whether the change is on
    /// disk.
    ///
    /// `true` for a hike with no context at all: nothing persisted the row in
    /// the first place, so nothing can bring it back and the files are free to
    /// go.
    @MainActor
    private static func persisted(
        _ hike: Hike,
        _ save: (ModelContext) throws -> Void
    ) -> Bool {
        guard let context = hike.modelContext else { return true }
        do {
            try save(context)
            return true
        } catch {
            HikePhotoStore.logger.error(
                """
                Kept a photo whose removal could not be saved: \
                \(error.localizedDescription, privacy: .public)
                """
            )
            return false
        }
    }

    /// Fire-and-forget: by the time this is reached the metadata half is
    /// already settled, so a delete that fails costs disk space until the next
    /// launch sweep and nothing else — and there is no screen where waiting
    /// for it would tell the user anything.
    ///
    /// "Already settled" is a precondition, not an observation. Every caller
    /// has to have committed the metadata half first — see
    /// ``remove(_:from:store:save:)`` for one photo and
    /// ``HikeDeletion/delete(_:store:save:)`` for a whole hike.
    @MainActor
    static func discardFiles(
        _ photos: [HikePhoto],
        from store: HikePhotoStore = .shared
    ) {
        discardFiles(photos.map(HikePhotoStore.PhotoFiles.init), from: store)
    }

    /// The same, from names snapshotted while the photos were still attached.
    ///
    /// What a whole-hike deletion holds: its photos go out of the store with
    /// the hike, so the only thing left to erase them by is what was read
    /// before they went.
    @MainActor
    static func discardFiles(
        _ files: [HikePhotoStore.PhotoFiles],
        from store: HikePhotoStore = .shared
    ) {
        guard !files.isEmpty else { return }
        Task(priority: .utility) { await erase(files, in: store) }
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
        _ files: [HikePhotoStore.PhotoFiles],
        in store: HikePhotoStore
    ) async {
        store.remove(files)
    }
}
