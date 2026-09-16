//
//  HikePhoto.swift
//  OpenHikes
//
//  A photo taken or imported while a hike was open, stored inline by SwiftData
//  as part of ``Hike/photos``.
//
//  Only the metadata lives here. The pixels live on disk under
//  ``HikePhotoStore``, keyed by ``HikePhoto/id``, for the same reason tiles do:
//  a SwiftData column is loaded whole whenever the row is touched, and a
//  handful of multi-megabyte images in one would be paid for by every screen
//  that reads a hike's title.
//

import CoreLocation
import Foundation

/// What placed a photo on the trail, when the app itself did not know where
/// the camera was.
///
/// `nil` — the absence of this value — is every photo OpenHikes took or
/// imported itself: the elevation graph's selection or the recording's last
/// accepted fix, both of which are the app's own answer to "where am I" and
/// need no explaining. A value means the photo came out of the system photo
/// library through ``LibraryPhotoMatch``, and says which of the two things the
/// asset carried was used to place it.
///
/// Stored so the gallery can be honest about the difference. A pin the app
/// watched the hiker stand on and a pin worked out from a clock four minutes
/// off the nearest fix are not the same claim, and a screen that draws them
/// identically is making the weaker one silently.
nonisolated enum PhotoMatchEvidence: String, Codable, Hashable, Sendable {
    /// The asset's own recorded position, snapped onto the route. Used when
    /// the walk had no fix close enough in time to place the photo by clock —
    /// a stretch that was walked through a GPS gap.
    case place = "place"
    /// The moment the photo was taken, against the route's own timestamps.
    /// The asset carried no position of its own.
    case time = "time"
    /// Both, and they agreed: the strongest of the three.
    case timeAndPlace = "timeAndPlace"
}

/// One photo attached to a hike.
///
/// The trail coordinate is optional and deliberately so — see
/// ``PhotoTrailAnchor`` for the cases that produce no anchor. An unanchored
/// photo is still a photo of the walk; it simply has no place to point at on
/// the map.
nonisolated struct HikePhoto: Codable, Hashable, Identifiable, Sendable {
    /// Stable identity, and the stem of the file the pixels are stored under.
    var id: UUID
    /// When the picture was taken (camera) or when it was imported (library).
    ///
    /// An imported asset's own creation date is deliberately not used: reading
    /// it means a `PHAsset` fetch, which means read access to the whole photo
    /// library — and the import path is built to need no photo-library
    /// permission at all. Import time is also the honest answer for what the
    /// gesture means: see ``HikePhotoImport``.
    var capturedAt: Date
    /// The stored file's extension, taken from the bytes themselves by
    /// ``ImageDataFormat/detect(in:)`` — `jpeg` for a captured frame, whatever
    /// the picked asset actually was for an import, so the original bytes (and
    /// the EXIF inside them) can be written through untouched.
    ///
    /// A plain `String` rather than a `UTType`: this is persisted, and an
    /// extension is the one part of an image format that is stable across OS
    /// releases.
    var pathExtension: String
    /// Where on the trail this photo belongs, or `nil` when nothing could be
    /// anchored — see ``PhotoTrailAnchor``.
    var latitude: Double?
    var longitude: Double?

    /// The `PHAsset` this photo was copied out of, for a photo that came from
    /// the system photo library rather than being taken in the app.
    ///
    /// Recorded for one job: the same picture must not be attached to one walk
    /// twice, whichever surface offers it — a second scan of the library, or
    /// the picker opened again on a selection that overlaps the first.
    /// Matching on the moment instead would be wrong twice over: two frames of
    /// a burst share a second, and a photo the user imported and then
    /// deliberately deleted from the hike would be refused forever.
    ///
    /// Both library surfaces fill it in. `PhotosPickerItem/itemIdentifier`
    /// carries it for a picked photo — the picker still runs out of process
    /// and still costs no photo-library permission, because the identifier is
    /// handed back with the selection rather than looked up in the library.
    ///
    /// Optional because a capture has no library asset behind it at all: it
    /// exists only inside OpenHikes unless the user opted into the mirror, and
    /// the mirrored copy is a new asset this app never sees the identity of.
    var assetLocalIdentifier: String?

    /// How this photo came to be pinned where it is, for a photo the app did
    /// not watch being taken. See ``PhotoMatchEvidence``.
    var matchEvidence: PhotoMatchEvidence?

    /// The community listing this photograph was copied out of, for one that
    /// arrived with somebody else's hike rather than being taken by this
    /// hiker. `nil` — the absence — is every photograph the hiker took or
    /// imported themselves, which is almost all of them.
    ///
    /// Recorded for one job, and it is a job nothing else on this type can
    /// do: **a photograph this hiker did not take must never be published
    /// under their name.** ``CommunityImport`` copies a listing's pictures
    /// into the saved hike so the trail is useful offline, and that saved hike
    /// is exactly the one the contribution flow then offers to add photographs
    /// to — see ``CommunityPublishingEligibility``. Without this field the
    /// *Add Photos* form opened pre-selected with the original author's
    /// pictures, one tap from being re-published onto their own trail under
    /// the importer's credit. ``CommunityPublisher/shareablePhotos(of:)`` and
    /// ``CommunityPublisher/selectedPhotos(of:excluding:)`` read it, and are
    /// the only things that do.
    ///
    /// Optional for the reason ``assetLocalIdentifier`` is, and one more: the
    /// rows written before this existed carry no key for it, and an optional
    /// is what lets them decode unchanged. See ``isOwn``.
    var importedFromListingID: String?

    /// When this picture was last sent to the community, or `nil` for one that
    /// never has been.
    ///
    /// Recorded so that a second send can leave it out. A hike's photographs
    /// can reach the public database twice over — with the walk itself, and
    /// again as a contribution onto a trail that is already there, which is
    /// now how a photograph added after publication gets on. Neither path can
    /// *amend* what it sent, by ``CommunitySchema``'s design, so a picture
    /// offered a second time is a second copy of it in the same gallery rather
    /// than a replacement. This is what lets the form open with the ones
    /// already up struck off and say which they are.
    ///
    /// It says *sent*, not *published*, and the distinction is the same one
    /// ``Hike/communitySubmissionID`` draws: a reviewer may not have looked
    /// yet, and may say no. Either way the copy is uploaded and sending it
    /// again would duplicate it, so the stamp goes on when CloudKit accepts
    /// the upload and never moves afterwards.
    ///
    /// Stamped by ``CommunityPublisher/markSent(_:on:at:)``, and only over the
    /// pictures whose files really left this device — a row whose pixels live
    /// on another device is dropped by the encode and is not sent, so it must
    /// not be marked as though it were.
    ///
    /// A new key in a blob written by every earlier version, which decodes as
    /// `nil` because it is optional: a photograph shared before this existed
    /// reads as never sent, which costs a hiker a duplicate they can strike
    /// off by hand and costs nothing else.
    var sentToCommunityAt: Date?

    init(
        id: UUID = UUID(),
        capturedAt: Date = .now,
        pathExtension: String = ImageDataFormat.jpeg.pathExtension,
        coordinate: CLLocationCoordinate2D? = nil,
        assetLocalIdentifier: String? = nil,
        matchEvidence: PhotoMatchEvidence? = nil,
        importedFromListingID: String? = nil
    ) {
        self.id = id
        self.capturedAt = capturedAt
        self.pathExtension = pathExtension
        latitude = coordinate?.latitude
        longitude = coordinate?.longitude
        self.assetLocalIdentifier = assetLocalIdentifier
        self.matchEvidence = matchEvidence
        self.importedFromListingID = importedFromListingID
    }

    /// Whether this photograph is the hiker's own to publish.
    ///
    /// The question every community path asks, written once so no caller has
    /// to remember which way the optional runs. See
    /// ``importedFromListingID``.
    var isOwn: Bool { importedFromListingID == nil }

    /// Where a photograph came from, as against where it sits on the trail.
    ///
    /// The three fields above that describe the *source* rather than the
    /// picture, gathered so they travel together: they are filled in by the
    /// surface that produced the photograph, read by nothing on the way to
    /// disk, and are the only part of ``HikePhoto`` that
    /// ``HikePhotoStore/store(_:capturedAt:coordinate:origin:)`` does not work
    /// out for itself. Gathering them also keeps that call and the hop in
    /// front of it inside the parameter count the linter allows, which is a
    /// smaller reason and a real one.
    struct Origin: Sendable {
        var assetLocalIdentifier: String?
        var matchEvidence: PhotoMatchEvidence?
        var importedFromListingID: String?

        /// A photograph with nothing to say about where it came from: one the
        /// app watched being taken. The ordinary case, and the reason every
        /// field here is optional.
        static var own: Self { Self() }
    }

    /// The trail position this photo was anchored to, if any.
    var coordinate: CLLocationCoordinate2D? {
        guard let latitude, let longitude else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// Whether this photo can point at a place on the map.
    var isAnchored: Bool { coordinate != nil }

    /// Whether a copy of this picture is already in the public database.
    ///
    /// See ``sentToCommunityAt``, whose *absence* is the whole of the answer:
    /// what matters to a form deciding what to offer is that a copy went, not
    /// when it went or whether anybody has approved it yet.
    var hasBeenSentToCommunity: Bool { sentToCommunityAt != nil }

    /// The file the pixels are stored under, relative to the photo directory.
    var fileName: String { "\(id.uuidString).\(pathExtension)" }

    /// The file the pre-rendered gallery thumbnail is stored under.
    ///
    /// Always JPEG regardless of what the original was: this is a
    /// re-derivable copy at a size the strip actually draws, so there is
    /// nothing to preserve and every reason to keep it small.
    var thumbnailFileName: String {
        "\(id.uuidString).\(ImageDataFormat.jpeg.pathExtension)"
    }
}

extension Hike {
    /// This hike's photos, newest last — the order a walk produces them in,
    /// which is also the order the gallery strip and the viewer page through.
    ///
    /// Sorted on read rather than kept sorted on write: an import can hand
    /// back several assets at once and out of order, and there is no second
    /// place for the order to be got wrong if there is no stored order.
    var orderedPhotos: [HikePhoto] {
        // Marked because this is a full sort behind a computed property, and a
        // computed property is invisible at its call sites: the viewer used to
        // read it six times per body pass without any of them looking like
        // work. A count that outruns `PhotoViewerBody` is the shape to catch.
        photos.sorted { lhs, rhs in
            // The timestamps are compared first and the identifiers only on a
            // tie. `UUID.uuidString` allocates a 36-character string, and
            // building the pair up front meant two allocations for *every*
            // comparison — O(n log n) of them for an ordering that two photos
            // taken in the same second are the only ones that need.
            if lhs.capturedAt != rhs.capturedAt { return lhs.capturedAt < rhs.capturedAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    var hasPhotos: Bool { !photos.isEmpty }

    /// Appends a photo whose pixels are already on disk.
    func addPhoto(_ photo: HikePhoto) {
        guard !photos.contains(where: { $0.id == photo.id }) else { return }
        photos.append(photo)
    }

    /// Forgets a photo. The file itself is removed by the caller through
    /// ``HikePhotoStore``, which is off-main work this main-actor model must
    /// not do.
    @discardableResult func removePhoto(id: UUID) -> HikePhoto? {
        guard let index = photos.firstIndex(where: { $0.id == id }) else { return nil }
        return photos.remove(at: index)
    }
}
