//
//  HikePhotoImage.swift
//  OpenHikes
//
//  Getting a decoded image from ``HikePhotoStore`` to a SwiftUI view without
//  decoding it on the main thread.
//
//  The store's work is off-main by contract, so a decoded image has a boundary
//  to cross and these are the boxes it crosses in. Same shape, and same
//  justification, as ``TileCache/MemoryTile``: the image is produced once and
//  never written to again, so the only thing crossing is a reference nobody
//  else holds.
//
//  Both conformances are declared below rather than on the types, because
//  which form is honest depends on the platform: `UIImage` is declared
//  `NS_SWIFT_SENDABLE` and `NSImage` is not.
//

import Foundation
import OpenHikesData

/// A decoded image on its way back to the main actor.
///
/// Kept as a box even though `PhotoImage` crosses on its own under UIKit, and
/// the reason is the AppKit branch: this is the one place either branch has to
/// say anything about image sendability. ``PhotoDisplay``,
/// ``PhotoLibraryReading/thumbnail(for:maxPixelSize:)`` and the discovery
/// controller are all written in terms of this type and stay plainly
/// `Sendable` on both, rather than each needing a platform conditional of its
/// own. The image is fully decoded before this is constructed and never
/// mutated afterwards.
nonisolated struct LoadedPhotoImage {
    let image: PhotoImage
}

/// A frame on its way *out* of the camera, for the same reason.
nonisolated struct CapturedFrame {
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

#if canImport(UIKit)
// Checked, because `UIImage` is declared `NS_SWIFT_SENDABLE`. The point of
// spelling it this way is that the compiler now reads the stored properties
// above: a later one that isn't `Sendable` is a build error rather than
// something an `@unchecked` silently absorbed.
extension LoadedPhotoImage: Sendable {}
extension CapturedFrame: Sendable {}
#elseif canImport(AppKit)
// `NSImage` carries no such declaration, so this branch keeps the unchecked
// form on the same argument it always rested on: the image is decoded before
// the box is built and never written to again. Verify that independently
// before an AppKit target is taken seriously — nothing builds this today.
extension LoadedPhotoImage: @unchecked Sendable {}
extension CapturedFrame: @unchecked Sendable {}
#endif

/// What ``HikePhotoLoader`` asks of a photo's files: ``HikePhotoStore``, in
/// the app.
///
/// A protocol for the reason ``PhotoLibraryReading`` is one: a suite can hold
/// a decode where it is, mid-flight, which no file on disk can be made to do
/// — and the moment a decode is held mid-flight is the one the loader's
/// cancellation contract is about.
nonisolated protocol HikePhotoReading: Sendable {
    func thumbnail(for photo: HikePhoto) -> PhotoImage?
    func displayImage(for photo: HikePhoto) -> PhotoImage?
    func hasImage(for photo: HikePhoto) -> Bool
}

nonisolated extension HikePhotoStore: HikePhotoReading {}

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
///
/// Dropped twice, because there are two windows for a cancellation to arrive
/// in. The reads ask again once the store is done, so a task cancelled during
/// a decode is handed ``PhotoDisplay/loading`` rather than the picture. And
/// the `show:` forms a view reads through ask a last time on the main actor,
/// after the hop back, which is the second window: until #1335 a view wrote
/// whatever came back into its state, whichever task owned that state by
/// then.
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
        in store: some HikePhotoReading
    ) async -> PhotoDisplay {
        guard !Task.isCancelled else { return .loading }
        guard let image = store.thumbnail(for: photo) else {
            return settled(.unavailable(unavailability(of: photo, in: store)))
        }
        return settled(.ready(LoadedPhotoImage(image: image)))
    }

    /// The viewer's read: the full picture rather than the strip's square.
    ///
    /// A cancelled task reports ``PhotoDisplay/loading`` rather than a
    /// failure: nothing was observed about the file, and the page that asked
    /// is either going away or about to ask again for a different photo.
    @concurrent
    static func display(
        for photo: HikePhoto,
        in store: some HikePhotoReading
    ) async -> PhotoDisplay {
        guard !Task.isCancelled else { return .loading }
        guard let image = store.displayImage(for: photo) else {
            return settled(.unavailable(unavailability(of: photo, in: store)))
        }
        return settled(.ready(LoadedPhotoImage(image: image)))
    }

    /// The strip's read, handed to `show` only while the task that asked
    /// still owns what it shows.
    ///
    /// The form a view's `.task(id:)` uses. SwiftUI cancels the task it
    /// replaces and starts the next one at once, without waiting, so the
    /// older answer can come back after the newer one has been drawn — and
    /// whatever it writes stays, the picture or even a spinner, because the
    /// newer task has finished. Asked on the main actor, where SwiftUI
    /// cancels, the check and the write are one step that a cancellation
    /// cannot come between.
    @MainActor
    static func thumbnail(
        for photo: HikePhoto,
        in store: some HikePhotoReading,
        show: (PhotoDisplay) -> Void
    ) async {
        let answer = await thumbnail(for: photo, in: store)
        guard !Task.isCancelled else { return }
        show(answer)
    }

    /// The viewer's read, handed to `show` only while the task that asked
    /// still owns the page. See ``thumbnail(for:in:show:)``.
    @MainActor
    static func display(
        for photo: HikePhoto,
        in store: some HikePhotoReading,
        show: (PhotoDisplay) -> Void
    ) async {
        let answer = await display(for: photo, in: store)
        guard !Task.isCancelled else { return }
        show(answer)
    }

    /// `answer`, unless the task that asked was cancelled while the store
    /// worked on it.
    ///
    /// Asked again because the decode ran to the end whatever happened
    /// meanwhile, and this is where its result is dropped: a picture is no
    /// news to a view that has moved on, and a failure found for it would be
    /// worse, for the reason ``display(for:in:)`` gives.
    private static func settled(_ answer: PhotoDisplay) -> PhotoDisplay {
        Task.isCancelled ? .loading : answer
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
        in store: some HikePhotoReading
    ) -> PhotoUnavailability {
        // Asked first and answered from the row alone. A place-only row has
        // no file and never had one, so the `fileExists` below would say
        // ``notOnThisDevice`` — which is the one wrong answer available: it
        // sends the hiker to look for the picture on another device.
        if photo.recordsPlaceOnly { return .placeOnly }
        return store.hasImage(for: photo) ? .unreadable : .notOnThisDevice
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
    /// on every device but the one it was added on — the camera writes its
    /// bytes here and so does an import, so that is the device holding the
    /// only copy, whatever took the picture — and what a file deleted
    /// underneath the app looks like anywhere.
    case notOnThisDevice
    /// The row was never a picture: it came out of a `<wpt>` in an imported
    /// `.gpx`, which records where a photograph was taken and cannot carry
    /// the photograph. See ``HikePhoto/isPlaceOnly``.
    ///
    /// Told apart from ``notOnThisDevice`` because the two are opposite
    /// promises. That one says the picture exists and is somewhere else, which
    /// invites the hiker to go and find it; this one says there is nothing to
    /// find, on any device, ever.
    case placeOnly
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
    /// A decode is in flight, or its task was cancelled before it ran or
    /// while it did. The states a spinner is the honest answer for.
    case loading
    case ready(LoadedPhotoImage)
    /// The store had nothing to give for a photo the hike still lists, and
    /// which of the two reasons it was. Final until the file comes back or the
    /// row goes.
    case unavailable(PhotoUnavailability)
}
