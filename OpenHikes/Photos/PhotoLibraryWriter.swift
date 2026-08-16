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
//  Importing *from* the library needs no authorization at all, which is why
//  there is no counterpart to this file on that side — `PhotosPicker` runs out
//  of process and hands back only what the user picked.
//

import Foundation
import os
import Photos

nonisolated enum PhotoLibraryWriter {
    private static let logger = Logger(
        subsystem: "OpenHikes",
        category: "PhotoLibrary"
    )

    /// Adds `data` to the library.
    ///
    /// - Returns: `false` if permission was refused or the write failed. The
    ///   caller has already stored its own copy by then, so this is a
    ///   secondary outcome and never a reason to lose the photo.
    @discardableResult static func save(_ data: Data, fileExtension: String) async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            logger.notice("Photo library save skipped: add-only access not granted.")
            return false
        }

        do {
            try await PHPhotoLibrary.shared().performChanges {
                let creation = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                // Names the resource so the library stores it under the format
                // it really is, rather than inferring one.
                options.originalFilename = "OpenHikes-\(UUID().uuidString).\(fileExtension)"
                creation.addResource(with: .photo, data: data, options: options)
            }
            return true
        } catch {
            logger.error(
                "Photo library save failed: \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }
}
