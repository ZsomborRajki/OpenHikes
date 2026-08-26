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
/// watched the walker stand on and a pin worked out from a clock four minutes
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

    /// The `PHAsset` this photo was copied out of, for a photo found in the
    /// system photo library rather than taken or picked in the app.
    ///
    /// Recorded for one job: a second scan of the library must offer only what
    /// the first one did not take. Matching on the moment instead would be
    /// wrong twice over — two frames of a burst share a second, and a photo
    /// the user imported and then deliberately deleted from the hike would be
    /// offered again forever.
    ///
    /// Optional because most photos have no library asset behind them at all:
    /// a capture exists only inside OpenHikes unless the user opted into the
    /// mirror, and a `PhotosPicker` import deliberately never learns the
    /// asset's identity — that would be a photo-library read, which the picker
    /// path exists to avoid.
    var assetLocalIdentifier: String?

    /// How this photo came to be pinned where it is, for a photo the app did
    /// not watch being taken. See ``PhotoMatchEvidence``.
    var matchEvidence: PhotoMatchEvidence?

    init(
        id: UUID = UUID(),
        capturedAt: Date = .now,
        pathExtension: String = ImageDataFormat.jpeg.pathExtension,
        coordinate: CLLocationCoordinate2D? = nil,
        assetLocalIdentifier: String? = nil,
        matchEvidence: PhotoMatchEvidence? = nil
    ) {
        self.id = id
        self.capturedAt = capturedAt
        self.pathExtension = pathExtension
        latitude = coordinate?.latitude
        longitude = coordinate?.longitude
        self.assetLocalIdentifier = assetLocalIdentifier
        self.matchEvidence = matchEvidence
    }

    /// The trail position this photo was anchored to, if any.
    var coordinate: CLLocationCoordinate2D? {
        guard let latitude, let longitude else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// Whether this photo can point at a place on the map.
    var isAnchored: Bool { coordinate != nil }

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
        photos.sorted { lhs, rhs in
            (lhs.capturedAt, lhs.id.uuidString) < (rhs.capturedAt, rhs.id.uuidString)
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
