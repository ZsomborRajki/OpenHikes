//
//  HikePhotoFile.swift
//  OpenHikes
//
//  One of the hiker's own photographs, on its way to the share sheet.
//
//  The stored file itself rather than a re-encode, which is the same choice
//  ``HikePhotoStore/exportOriginal(of:named:into:)`` makes for an archive and
//  the opposite of the one ``HikePhotoStore/exportCopy(of:maxPixelSize:quality:named:into:)``
//  makes for publishing. The reasoning is the same as the archive's: these
//  pixels live in exactly one place, so handing back anything lossier than the
//  file being shared is not a share. The full EXIF block travels with it,
//  camera GPS included — this is the hiker's own photograph going somewhere
//  the hiker picked, and the app does not get to decide that a picture of a
//  trail they walked is too revealing to send to whoever they meant to send it
//  to. Publishing to strangers is the case that strips it, and it still does.
//

import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// A photograph the share sheet can carry.
///
/// Carries a path and a name rather than a ``HikePhoto``, for the reason
/// ``HikeGPXFile`` carries a track rather than a `Hike`: `ShareLink` hands the
/// exporter to the system, which calls it off the main actor, where a `@Model`
/// must not be read.
nonisolated struct HikePhotoFile: Transferable, Sendable {
    /// The stored file. Copied by the system rather than handed over — see
    /// ``SentTransferredFile`` below, which does not ask for access to the
    /// original.
    let source: URL
    /// What it arrives called, from ``GPXExport/photoFileName(hikeTitle:position:pathExtension:)``.
    let suggestedName: String

    /// A photo added on another device has a row in the store and no file
    /// here — an ordinary state rather than a fault, and the one the share has
    /// to be able to refuse. See ``PhotoUnavailability/notOnThisDevice``.
    struct NotOnThisDevice: Error {}

    /// The file and nothing beside it, for the reason ``HikeArchiveFile`` gives:
    /// registering a `DataRepresentation` as well puts the loose-bytes
    /// behaviour back whatever the preference order says, and a receiver that
    /// wants bytes reads them out of the file.
    ///
    /// Exported as `.image` rather than as a concrete type because the stored
    /// extension is per photograph and this is per type — a capture is JPEG and
    /// an import is whatever the library held. The name carries the real one,
    /// which is what every receiver resolves against.
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .image) { file in
            guard FileManager.default.fileExists(atPath: file.source.path) else {
                throw NotOnThisDevice()
            }
            return SentTransferredFile(file.source)
        }
        .suggestedFileName { $0.suggestedName }
    }
}
