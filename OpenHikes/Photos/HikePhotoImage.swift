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
    /// When the shutter fired, as the camera reported it — see
    /// ``CameraCaptureMetadata``. `nil` when it reported nothing readable,
    /// which is the only case where the import has to fall back to a clock.
    ///
    /// It travels with the frame rather than being read later because the
    /// image itself carries none of it: a `UIImage` is pixels, and the
    /// dictionary this comes from is handed over once, to the delegate, and
    /// then gone.
    let capturedAt: Date?

    init(image: PhotoImage, capturedAt: Date? = nil) {
        self.image = image
        self.capturedAt = capturedAt
    }
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
    /// The strip's read, and the map callout's.
    ///
    /// Three-state like the viewer's below, and for the same reason: a tile
    /// that drew the same grey square for "decoding" and for "there is no
    /// file" was a broken picture with nothing said about it, on the surface a
    /// second device sees first.
    @concurrent
    static func thumbnail(
        for photo: HikePhoto,
        in store: HikePhotoStore
    ) async -> PhotoDisplay {
        guard !Task.isCancelled else { return .loading }
        return RenderSignpost.interval("PhotoThumbnailDecoded") {
            guard let image = store.thumbnail(for: photo) else {
                return PhotoDisplay.unavailable(unavailability(of: photo, in: store))
            }
            return .ready(LoadedPhotoImage(image: image))
        }
    }

    /// The viewer's read: the full picture rather than the strip's square.
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
                return PhotoDisplay.unavailable(unavailability(of: photo, in: store))
            }
            return .ready(LoadedPhotoImage(image: image))
        }
    }

    /// Which of the two empty answers this is, asked only once a decode has
    /// already failed.
    ///
    /// The `fileExists` behind it is never paid on the path where the picture
    /// draws, which is the overwhelming majority of them — and the answer is
    /// worth a stat call on the path where it doesn't, because the two states
    /// deserve different words and only one of them can be retried.
    private static func unavailability(
        of photo: HikePhoto,
        in store: HikePhotoStore
    ) -> PhotoUnavailability {
        store.hasImage(for: photo) ? .unreadable : .notOnThisDevice
    }
}

/// Why a photo the hike still lists cannot be drawn.
///
/// The distinction is the whole of what a second device is owed. Photo files
/// do not travel — mirroring carries ``Hike/photos`` and carries no files, and
/// that is a decision rather than a gap; see *Settled decisions* in the
/// repository instructions — so the ordinary case on a second device is a
/// photo that is fine everywhere except here, which is a sentence to say
/// rather than a picture to fail at drawing.
nonisolated enum PhotoUnavailability: Sendable {
    /// No file under the name the row claims. What a mirrored photo looks like
    /// on every device but the one that took it, and what a file deleted
    /// underneath the app looks like anywhere.
    case notOnThisDevice
    /// A file is there and could not be decoded — bytes still arriving from a
    /// restore, a volume that wasn't mounted, a truncated write. The one of
    /// the two that is worth asking about again.
    case unreadable
}

/// What one page of the full-screen viewer, or one tile of the strip, is
/// showing.
///
/// Three cases rather than an optional image, because the optional could not
/// tell the two empty answers apart: ``HikePhotoStore/displayImage(for:)``
/// returns `nil` both for a decode still to come and for a file that is not
/// there at all, and the viewer drew a spinner for both. A photo whose bytes
/// had gone — never on this device, restored from a backup that didn't carry
/// it, deleted underneath the app — therefore spun forever, with nothing said
/// and nothing to press.
nonisolated enum PhotoDisplay: Sendable {
    /// A decode is in flight, or was cancelled before it ran. The two states a
    /// spinner is the honest answer for.
    case loading
    case ready(LoadedPhotoImage)
    /// The store had nothing to give for a photo the hike still lists, and
    /// which of the two reasons it was. Final until the file comes back or the
    /// row goes.
    case unavailable(PhotoUnavailability)
}
