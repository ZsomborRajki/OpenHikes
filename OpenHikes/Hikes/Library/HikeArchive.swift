//
//  HikeArchive.swift
//  OpenHikes
//
//  A hike leaving the app with its photographs beside it, rather than only the
//  line it was walked along.
//
//  ``GPXExport`` is the other, smaller export and stays exactly as it was: one
//  `.gpx` file, which is what a GPX reader can match and open. This is the
//  second one, and it exists because a `.gpx` cannot carry pixels. A
//  photograph's bytes live under ``HikePhotoStore`` on this device and nowhere
//  else — they are not mirrored to iCloud, the copy in the system photo
//  library is opt-in and off by default, and until now no file the app
//  produced contained one. So the pictures from a hike existed as a single
//  copy, in one app's container, on one phone, with no way out at all. This is
//  the way out.
//
//  **The shape is a folder in a zip, and every part of that is load-bearing.**
//
//      Thumsee Loop-2026-06-12.zip
//      └── Thumsee Loop-2026-06-12/
//          ├── Thumsee Loop-2026-06-12.gpx
//          └── Photos/
//              ├── photo-1.jpeg
//              └── photo-2.heic
//
//  A zip because a share sheet hands over one file and `SentTransferredFile`
//  is one URL; a folder *inside* it because expanding an archive that sprays
//  a `.gpx` and a `Photos/` directory into whatever folder the hiker happened
//  to be in is a rude thing to do to somebody's Downloads. The `.gpx` keeps
//  the archive's own name so the two halves are recognisably one export after
//  they are separated, which they will be.
//
//  **The originals travel, not re-encodes.** ``CommunityPublisher`` bounds and
//  strips its copies because it publishes to strangers on a quota this app
//  pays for. Neither applies here: this archive is the hiker's own, and a
//  rescue that hands back something lossier than the file it rescued is not
//  one. The consequence is stated rather than hidden — the full EXIF block
//  goes with each photograph, camera GPS included, which matters the moment
//  the hiker sends the archive to somebody else rather than to their own Files
//  app. That is the cost of the archive being a real rescue, and it is the
//  hiker's own file: the app does not re-encode it behind their back.
//
//  **`<link>` is written only for a photograph that actually landed.** This is
//  the whole reason the copy happens before the markup rather than after it.
//  A hike holds photo rows whose files this device has never had — the
//  metadata mirrors and the pixels do not, which is what
//  ``PhotoUnavailability/notOnThisDevice`` exists to say — and a `<wpt>`
//  carrying `href="Photos/photo-2.jpeg"` for one of those would be the exact
//  broken promise ``GPXExport/Photograph`` refused to make. The waypoint is
//  still written, because *a photo was taken here* remains true and is the
//  part GPX can carry; only the link is dropped.
//

import CoreLocation
import CoreTransferable
import Foundation
import OpenHikesData
import UniformTypeIdentifiers

/// One hike's worth of files, ready to be written and zipped.
///
/// A `Sendable` snapshot for the same reason ``GPXExport/Track`` is one: the
/// share sheet calls its exporter on whatever executor it likes, and a `Hike`
/// is a `@Model` that must be read where its context lives.
nonisolated struct HikeArchive: Sendable, Equatable {
    /// One photograph the archive carries.
    ///
    /// Holds ``HikePhotoStore/PhotoFiles`` rather than a ``HikePhoto`` because
    /// the copy runs off the main actor, long after the model graph it was
    /// read from is out of reach — the same snapshot the measurement and the
    /// erase are handed.
    struct Photograph: Sendable, Equatable {
        var files: HikePhotoStore.PhotoFiles
        /// What it is called inside `Photos/`, and so the tail of the `href`
        /// the waypoint carries.
        var fileName: String
        /// `nil` for an unanchored photograph, which the archive carries and
        /// the `.gpx` cannot mention — `lat` and `lon` are required attributes
        /// on `<wpt>`, and ``HikePhoto``'s coordinate is optional on purpose.
        /// Such a photograph is still a photograph of the walk; it is in the
        /// zip, and only its position is missing, which was missing already.
        var coordinate: RouteCoordinate?
        var capturedAt: Date
    }

    /// The route, its metadata, and — once ``HikeArchive/write(_:store:)`` has
    /// found out which pictures are on this device — its waypoints.
    ///
    /// Arrives here with ``GPXExport/Track/photographs`` empty, and that is
    /// deliberate: the waypoints an archive writes are built from
    /// ``photographs`` below, so there is one source of truth for what the
    /// file claims rather than two that can disagree about a missing picture.
    var track: GPXExport.Track
    /// In ``Hike/orderedPhotos`` order, which is the order the gallery draws
    /// them and so the order the numbering in `photo-1`, `photo-2` will look
    /// right in.
    var photographs: [Photograph]

    /// The folder inside the zip, the `.gpx` inside that, and the zip itself
    /// all take this name.
    var stem: String { GPXExport.archiveStem(for: track) }
}

nonisolated extension HikeArchive {
    /// The directory inside the archive the pictures go in.
    static let photoDirectoryName = "Photos"

    /// Builds the archive on disk and returns the `.zip`.
    ///
    /// `@concurrent` for the reason ``GPXExport/writeTemporaryFile(for:)`` is:
    /// the work stays inside the sharing task's tree and carries its priority,
    /// and copying a walk's worth of full-size photographs is emphatically not
    /// something to do on the thread drawing the sheet.
    ///
    /// Staged under ``GPXExport/stagingDirectory`` rather than a directory of
    /// its own, so the purge that already runs there sweeps abandoned archives
    /// too — and an archive is the larger thing to leave behind.
    ///
    /// - Returns: The `.zip`, which the caller hands to the share sheet.
    @concurrent
    static func write(
        _ archive: HikeArchive,
        store: HikePhotoStore = .shared
    ) async throws -> URL {
        assertOffMainThread("Archiving a hike must stay off the main thread")
        let directory = GPXExport.stagingDirectory
        GPXExport.purgeStagedExports(in: directory, before: .now - stagedArchiveLifetime)

        let staged = directory.appending(
            path: UUID().uuidString,
            directoryHint: .isDirectory
        )
        let root = try stage(archive, in: staged, store: store)
        return try zip(root, named: "\(archive.stem).zip", into: staged)
    }

    /// Builds the folder that goes inside the zip, and returns it.
    ///
    /// Separated from the zipping so a suite can assert on what an archive
    /// actually contains. The zip is a real one and the test that says so
    /// checks its header, but the substance — which pictures landed, what the
    /// `.gpx` claims about them — lives here, and an `xcodebuild test` on a
    /// simulator has no `unzip` to look inside an archive with.
    ///
    /// - Parameter directory: Created if it does not exist. The caller owns it.
    static func stage(
        _ archive: HikeArchive,
        in directory: URL,
        store: HikePhotoStore = .shared
    ) throws -> URL {
        assertOffMainThread("Archiving a hike must stay off the main thread")
        let stem = archive.stem
        let root = directory.appending(path: stem, directoryHint: .isDirectory)
        let photoDirectory = root.appending(
            path: photoDirectoryName,
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: photoDirectory,
            withIntermediateDirectories: true
        )

        // The copies first, and the markup second, so the file can only link
        // pictures that are really beside it — see this file's header.
        var track = archive.track
        track.photographs = archive.photographs.compactMap { photograph in
            let landed = store.exportOriginal(
                of: photograph.files,
                named: photograph.fileName,
                into: photoDirectory
            ) != nil
            guard let coordinate = photograph.coordinate else { return nil }
            return GPXExport.Photograph(
                coordinate: coordinate,
                capturedAt: photograph.capturedAt,
                linkHref: landed ? "\(photoDirectoryName)/\(photograph.fileName)" : nil
            )
        }

        let document = root.appending(path: "\(stem).gpx", directoryHint: .notDirectory)
        try GPXExport.data(for: track).write(to: document, options: .atomic)
        return root
    }

    /// An archive is bigger than a `.gpx` and a share of one takes longer, so
    /// it is given the hour ``GPXExport`` gives an export rather than less.
    private static let stagedArchiveLifetime: TimeInterval = 3600

    /// Zips `folder` and returns the archive, written into `directory`.
    ///
    /// `NSFileCoordinator`'s `.forUploading` is the system's own zip and the
    /// reason this needs no dependency: it is what Files.app's *Compress* uses,
    /// it archives the folder rather than its loose contents, and it is
    /// available everywhere the app runs.
    ///
    /// The archive it produces is temporary and is deleted when the accessor
    /// returns, so the move out has to happen *inside* the block. That is the
    /// one thing about this API that is easy to get wrong and impossible to
    /// notice in a test that reads the URL afterwards.
    private static func zip(
        _ folder: URL,
        named name: String,
        into directory: URL
    ) throws -> URL {
        let destination = directory.appending(path: name, directoryHint: .notDirectory)
        var coordinationError: NSError?
        var moveError: Error?
        NSFileCoordinator().coordinate(
            readingItemAt: folder,
            options: [.forUploading],
            error: &coordinationError
        ) { archived in
            do {
                try FileManager.default.moveItem(at: archived, to: destination)
            } catch {
                moveError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let moveError { throw moveError }
        return destination
    }
}

// MARK: - Reading the hike

@MainActor
extension HikeArchive {
    /// Reads `hike` where its SwiftData context lives, and hands on the
    /// `Sendable` copy the archiver works from.
    ///
    /// Isolation spelled out rather than inherited. A `@Model` is main-actor
    /// and this reads one, so the annotation is the truth either way — but
    /// ``HikeArchive`` is a `nonisolated` type, and an unannotated extension
    /// of one resolves differently across the toolchains this project builds
    /// on. Stating it costs a line and removes the question.
    ///
    /// Every photograph is carried, anchored or not. The `.gpx` can only
    /// mention the anchored ones — see ``Photograph/coordinate`` — but the
    /// point of the archive is the pixels, and an unanchored photograph's
    /// pixels are exactly as irreplaceable as an anchored one's.
    ///
    /// The track arrives with its own photographs emptied, because
    /// ``write(_:store:)`` rebuilds them from what it manages to copy.
    init(hike: Hike) {
        var track = GPXExport.Track(hike: hike)
        track.photographs = []
        self.init(
            track: track,
            photographs: hike.orderedPhotos.enumerated().map { index, photo in
                Photograph(
                    files: HikePhotoStore.PhotoFiles(photo),
                    // One-based, because this is a name a person reads in a
                    // folder rather than an index anything computes with.
                    fileName: "photo-\(index + 1).\(photo.pathExtension)",
                    coordinate: photo.coordinate.map { coordinate in
                        RouteCoordinate(
                            latitude: coordinate.latitude,
                            longitude: coordinate.longitude
                        )
                    },
                    capturedAt: photo.capturedAt
                )
            }
        )
    }
}

// MARK: - Sharing

/// The share sheet's view of a hike and its pictures: a `.zip`, written on
/// demand.
///
/// A second `Transferable` alongside ``HikeGPXFile`` rather than a replacement
/// for it, and that is the decision this feature turns on. A share sheet builds
/// its "Copy to <App>" row by matching the *file* against what each installed
/// app declares it opens, so handing over a zip is handing over something no
/// GPX reader can see inside. The hiker sharing a route to their mapping app
/// and the hiker rescuing their photographs want two different files, and each
/// gets the one that works — see ``HikeDetailView/archiveButton``.
///
/// Nothing is written until a destination is picked, so offering the action
/// costs nothing.
nonisolated struct HikeArchiveFile: Transferable, Sendable {
    let archive: HikeArchive

    /// The file and nothing beside it, for the reason ``HikeGPXFile`` gives:
    /// registering a `DataRepresentation` of the same type as well puts the
    /// loose-bytes behaviour back whatever the preference order says, and a
    /// receiver that wants bytes reads them out of the file.
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .zip) { file in
            SentTransferredFile(try await HikeArchive.write(file.archive))
        }
        .suggestedFileName { "\($0.archive.stem).zip" }
    }
}
