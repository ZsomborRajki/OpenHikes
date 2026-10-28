//
//  PhotoLibraryWriter.swift
//  OpenHikes
//
//  The opt-in second copy: a photo taken in OpenHikes also landing in the
//  system photo library.
//
//  Two decisions worth stating. It asks for `.addOnly` authorization, which is
//  the narrowest thing the Photos framework offers — the app gains the ability
//  to add an asset and no ability whatsoever to read the user's library, and
//  the prompt says exactly that. And it is asked for here, on the first photo
//  saved after the setting is turned on, rather than at launch or when the
//  switch is flipped: a permission prompt is only honest at the moment the
//  thing it permits is actually happening.
//
//  There is deliberately no "OpenHikes" album, and that follows from the
//  first decision rather than being independent of it. Finding an album means
//  fetching one, and creating an album is a `.readWrite` change request;
//  under add-only both come back empty or fail, so an album would mean asking
//  for read access to the user's entire photo library in order to file a copy
//  of a picture the app already has. The asset lands in Recents, where the
//  Photos app already attributes it to OpenHikes and where a user who wants
//  an album can make one. The app's own gallery is the hike-shaped view of
//  these pictures.
//
//  What lands there is the whole photograph, not only its pixels. The setting
//  promises the user this photo *in their library*, and a copy with no date
//  and no place is a lesser thing than the one the app kept: it sorts into
//  Recents under the moment it was filed rather than the moment it was taken,
//  and appears nowhere in Places, on a picture the app could say both of. So
//  the capture time and the trail coordinate go onto the asset *and* into the
//  file's own EXIF — see ``PhotoMetadataStamp`` for why both.
//
//  Choosing individual photos through `PhotosPicker` needs no photo-library
//  authorization: it runs out of process and hands back only what the user
//  picked. *Find Photos* scans the library through ``PhotosLibraryReader``,
//  which owns its separate read/write request.
//
//  None of it runs on the main actor, and the `@concurrent` below is what says
//  so — see the protocol requirement for why it is stated there. Getting that
//  wrong here was not a hitch but a crash: a change block formed inside a
//  main-actor body inherits main-actor isolation, PhotoKit runs it on
//  `com.apple.PHPhotoLibrary.changes`, and the isolation check Swift emits at
//  the top of it trapped on every single mirrored save.
//

import CoreLocation
import Foundation
import os
import Photos
import Synchronization

/// Filing a copy of a photo in the system library.
///
/// A protocol for the same reason ``PhotoLibraryReading`` is one: the
/// authorization prompt cannot be answered from a test, and a suite must not
/// write assets into whatever library the machine running it happens to have.
/// What a test can watch through it is the thing that was getting lost — the
/// date and the place travelling with the bytes.
protocol PhotoLibraryWriting: Sendable {
    /// Adds `data` to the library, with the moment and the place the app knows
    /// it was taken.
    ///
    /// - Parameter coordinate: `nil` when the app has no position for this
    ///   photograph, which is a real case — location refused, or a hike with
    ///   no route point to stand on. The date is still recorded.
    /// - Returns: The local identifier of the asset the library created, or
    ///   `nil` if permission was refused or the write failed. The caller has
    ///   already stored its own copy by then, so a `nil` is a secondary
    ///   outcome and never a reason to lose the photo. The identifier is what
    ///   lets the caller recognise this copy when the library is next read —
    ///   by *Find Photos*, or the picker — as the photograph the hike already
    ///   holds rather than a new one to offer.
    ///
    /// `@concurrent`, and on the requirement rather than only on the
    /// implementation, because *running off the main actor is part of what is
    /// being promised here* rather than an implementation detail of one
    /// conformance. Every caller is main-actor isolated, and under
    /// approachable concurrency a bare `nonisolated async` function runs on
    /// its caller's executor — so without this the whole body below, PhotoKit's
    /// first-touch daemon handshake included, happens on the main thread while
    /// looking exactly like offloaded work. Stating it on the protocol is also
    /// what keeps a stub from quietly witnessing it back onto main and taking
    /// the regression test with it.
    @concurrent
    @discardableResult func save(
        _ data: Data,
        fileExtension: String,
        capturedAt: Date,
        coordinate: CLLocationCoordinate2D?
    ) async -> String?
}

nonisolated struct PhotoLibraryWriter: PhotoLibraryWriting {
    private static let logger = Logger(
        subsystem: "OpenHikes",
        category: "PhotoLibrary"
    )

    @concurrent
    @discardableResult func save(
        _ data: Data,
        fileExtension: String,
        capturedAt: Date,
        coordinate: CLLocationCoordinate2D?
    ) async -> String? {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            Self.logger.notice("Photo library save skipped: add-only access not granted.")
            return nil
        }

        // Called straight through rather than hopped off to again: the body
        // is already on the concurrent executor, and `PhotoMetadataStamp`
        // asserts as much. Falls back to the original bytes rather than
        // failing the save — a copy with no EXIF is worse than one with it, a
        // copy that never arrived is worse than both, and the asset's own date
        // and location are set below regardless.
        let bytes = PhotoMetadataStamp.stamped(
            data,
            capturedAt: capturedAt,
            coordinate: coordinate
        ) ?? data
        // The placeholder is the only moment the created asset's identity is
        // offered, and add-only access is enough to be told it — it is the
        // one thing about the library this app is allowed to know, because it
        // put it there. Carried out of the change block through a lock
        // because PhotoKit runs that block on its own queue.
        let created = Mutex<String?>(nil)
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let creation = PHAssetCreationRequest.forAsset()
                let identifier = creation.placeholderForCreatedAsset?.localIdentifier
                created.withLock { $0 = identifier }
                // Set on the asset as well as written into the bytes: this is
                // what the Photos app indexes for Recents and for Places, and
                // it is the half that still lands if the stamp above could not
                // rewrite the file.
                creation.creationDate = capturedAt
                if let coordinate {
                    creation.location = CLLocation(
                        latitude: coordinate.latitude,
                        longitude: coordinate.longitude
                    )
                }
                let options = PHAssetResourceCreationOptions()
                // Names the resource so the library stores it under the format
                // it really is, rather than inferring one.
                options.originalFilename = "OpenHikes-\(UUID().uuidString).\(fileExtension)"
                creation.addResource(with: .photo, data: bytes, options: options)
            }
            return created.withLock { $0 }
        } catch {
            Self.logger.error(
                "Photo library save failed: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }
}
