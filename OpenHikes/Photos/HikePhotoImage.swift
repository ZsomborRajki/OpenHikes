//
//  HikePhotoImage.swift
//  OpenHikes
//
//  Getting a decoded image from ``HikePhotoStore`` to a SwiftUI view without
//  decoding it on the main thread.
//
//  The store's work is off-main by contract and a `UIImage` is not `Sendable`,
//  so the two ends need a box to meet in. Same shape, and same justification,
//  as ``TileCache/MemoryTile``: the image is produced once and never written
//  to again, so the only thing crossing the boundary is a reference nobody
//  else holds.
//

import Foundation

/// A decoded image on its way back to the main actor.
///
/// `@unchecked Sendable` because `PhotoImage` isn't `Sendable` and there is no
/// Swift-native image type to replace it with. The image is fully decoded
/// before this is constructed and never mutated afterwards.
nonisolated struct LoadedPhotoImage: @unchecked Sendable {
    let image: PhotoImage
}

/// A frame on its way *out* of the camera, for the same reason.
nonisolated struct CapturedFrame: @unchecked Sendable {
    let image: PhotoImage
}

/// The two reads a photo view makes, each on the concurrent executor.
///
/// `@concurrent` rather than `Task.detached`: these stay part of the caller's
/// task, so a `.task(id:)` that goes away — a gallery tile scrolled off, a
/// viewer dismissed mid-decode — carries its cancellation here, and no
/// cancellation handler has to be written by hand.
///
/// What that cancellation buys is skipping a decode that hasn't started.
/// ImageIO's is not interruptible once underway, and the store checks nothing,
/// so a decode already in flight runs to completion and only its result is
/// dropped. That is the honest limit of it: the win is a fast scroll not
/// queueing a decode per tile it passed, not a decode being cut short.
nonisolated enum HikePhotoLoader {
    @concurrent
    static func thumbnail(
        for photo: HikePhoto,
        in store: HikePhotoStore
    ) async -> LoadedPhotoImage? {
        guard !Task.isCancelled else { return nil }
        return RenderSignpost.interval("PhotoThumbnailDecoded") {
            store.thumbnail(for: photo).map(LoadedPhotoImage.init)
        }
    }

    @concurrent
    static func displayImage(
        for photo: HikePhoto,
        in store: HikePhotoStore
    ) async -> LoadedPhotoImage? {
        guard !Task.isCancelled else { return nil }
        return RenderSignpost.interval("PhotoImageDecoded") {
            store.displayImage(for: photo).map(LoadedPhotoImage.init)
        }
    }
}
