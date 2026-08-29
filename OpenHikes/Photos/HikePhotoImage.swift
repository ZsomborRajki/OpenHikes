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

    /// The viewer's read, which unlike the strip's has to say *which* of two
    /// things happened when no image comes back.
    ///
    /// A cancelled task reports ``PhotoDisplay/loading`` rather than a
    /// failure: nothing was observed about the file, and the page that asked
    /// is either going away or about to ask again for a different photo.
    @concurrent
    static func display(
        for photo: HikePhoto,
        in store: HikePhotoStore
    ) async -> PhotoDisplay {
        guard !Task.isCancelled else { return .loading }
        return RenderSignpost.interval("PhotoImageDecoded") {
            guard let image = store.displayImage(for: photo) else {
                return PhotoDisplay.unavailable
            }
            return .ready(LoadedPhotoImage(image: image))
        }
    }
}

/// What one page of the full-screen viewer is showing.
///
/// Three cases rather than an optional image, because the optional could not
/// tell the two empty answers apart: ``HikePhotoStore/displayImage(for:)``
/// returns `nil` both for a decode still to come and for a file that is not
/// there at all, and the viewer drew a spinner for both. A photo whose bytes
/// had gone — never synced onto this device, restored from a backup that
/// didn't carry it, deleted underneath the app — therefore spun forever, with
/// nothing said and nothing to press.
nonisolated enum PhotoDisplay: Sendable {
    /// A decode is in flight, or was cancelled before it ran. The two states a
    /// spinner is the honest answer for.
    case loading
    case ready(LoadedPhotoImage)
    /// The store had nothing to give for a photo the hike still lists. Final
    /// until the file comes back or the row goes — which is why the page that
    /// draws this offers both.
    case unavailable
}
