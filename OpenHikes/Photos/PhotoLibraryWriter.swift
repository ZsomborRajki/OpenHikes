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
//  Importing *from* the library needs no authorization at all, which is why
//  there is no counterpart to this file on that side — `PhotosPicker` runs out
//  of process and hands back only what the user picked.
//

import CoreLocation
import Foundation
import os
import Photos

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
    /// - Returns: `false` if permission was refused or the write failed. The
    ///   caller has already stored its own copy by then, so this is a
    ///   secondary outcome and never a reason to lose the photo.
    @discardableResult func save(
        _ data: Data,
        fileExtension: String,
        capturedAt: Date,
        coordinate: CLLocationCoordinate2D?
    ) async -> Bool
}

nonisolated struct PhotoLibraryWriter: PhotoLibraryWriting {
    private static let logger = Logger(
        subsystem: "OpenHikes",
        category: "PhotoLibrary"
    )

    @discardableResult func save(
        _ data: Data,
        fileExtension: String,
        capturedAt: Date,
        coordinate: CLLocationCoordinate2D?
    ) async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            Self.logger.notice("Photo library save skipped: add-only access not granted.")
            return false
        }

        let bytes = await Self.stamped(
            data,
            capturedAt: capturedAt,
            coordinate: coordinate
        )
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let creation = PHAssetCreationRequest.forAsset()
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
            return true
        } catch {
            Self.logger.error(
                "Photo library save failed: \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }

    /// The metadata rewrite, off the main thread.
    ///
    /// `@concurrent` rather than a bare `nonisolated`: every caller of this
    /// file is main-actor isolated, and under approachable concurrency a
    /// `nonisolated async` function runs on its caller's executor — so without
    /// it the ImageIO work below would happen on the main thread while looking
    /// exactly like offloaded work.
    ///
    /// Falls back to the original bytes rather than failing the save. A copy
    /// with no EXIF is worse than one with it; a copy that never arrived is
    /// worse than both, and the asset's own date and location are set
    /// regardless.
    @concurrent
    private static func stamped(
        _ data: Data,
        capturedAt: Date,
        coordinate: CLLocationCoordinate2D?
    ) async -> Data {
        PhotoMetadataStamp.stamped(
            data,
            capturedAt: capturedAt,
            coordinate: coordinate
        ) ?? data
    }
}
