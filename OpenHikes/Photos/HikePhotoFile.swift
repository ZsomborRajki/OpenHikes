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
//  **A Wikimedia Commons copy is the one exception to sending the file as it
//  is.** It is not the hiker's photograph, and the app may hand it on only on
//  its licence's terms — the author, the licence and the source page going
//  with it. Those three were kept on the photo's row rather than in its bytes,
//  and the message the share sheet sends beside a file reaches Messages and
//  Mail and nothing else: AirDrop, Save to Files and every app that takes
//  only the file would get a picture with no credit at all. So such a copy is
//  rewritten with its credit on the way out, losslessly — see
//  ``PhotoMetadataStamp/credited(_:with:)`` — and a copy that cannot be is not
//  sent.
//

import CoreTransferable
import Foundation
import OpenHikesData
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
    /// The credit a Commons copy goes out carrying, from
    /// ``CommonsPhotoCredit/init(_:)``, and `nil` for every other photograph
    /// — which goes out as the stored file.
    var credit: CommonsPhotoCredit?

    /// A photo added on another device has a row in the store and no file
    /// here — an ordinary state rather than a fault, and the one the share has
    /// to be able to refuse. See ``PhotoUnavailability/notOnThisDevice``.
    struct NotOnThisDevice: Error {}

    /// A Commons copy whose credit could not be written into it, and which is
    /// therefore not sent: the licence that lets the app show the picture is
    /// the one that says it may not go anywhere uncredited.
    struct CreditNotWritten: Error {}

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
            guard let owed = file.credit else { return SentTransferredFile(file.source) }
            return SentTransferredFile(
                try await credited(file.source, with: owed, named: file.suggestedName)
            )
        }
        .suggestedFileName { $0.suggestedName }
    }
}

nonisolated extension HikePhotoFile {
    /// A credited copy of `source`, staged where the share sheet can take it.
    ///
    /// `@concurrent` and staged under ``GPXExport/stagingDirectory`` for the
    /// reasons ``HikeArchive/write(_:store:)`` is: a full-size photograph is
    /// not read on the thread drawing the sheet, and the purge that already
    /// runs there sweeps a copy the destination has finished with.
    @concurrent
    static func credited(
        _ source: URL,
        with credit: CommonsPhotoCredit,
        named name: String
    ) async throws -> URL {
        let directory = GPXExport.stagingDirectory
        GPXExport.purgeStagedExports(in: directory, before: .now - stagedCopyLifetime)
        return try stageCredited(
            source,
            with: credit,
            named: name,
            in: directory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        )
    }

    /// Writes the credited copy into `directory` and returns it.
    ///
    /// Separated from the staging location so a suite can read what a share
    /// would really send.
    ///
    /// - Throws: ``CreditNotWritten`` when the bytes cannot carry the credit.
    static func stageCredited(
        _ source: URL,
        with credit: CommonsPhotoCredit,
        named name: String,
        in directory: URL
    ) throws -> URL {
        assertOffMainThread("Crediting a photo must stay off the main thread")
        guard let credited = PhotoMetadataStamp.credited(try Data(contentsOf: source), with: credit) else {
            throw CreditNotWritten()
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appending(path: name, directoryHint: .notDirectory)
        try credited.write(to: destination, options: .atomic)
        return destination
    }

    /// The hour ``GPXExport`` gives a staged export, for the same slack.
    private static let stagedCopyLifetime: TimeInterval = 3600
}
