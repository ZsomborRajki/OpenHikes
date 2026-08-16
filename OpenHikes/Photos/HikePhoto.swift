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

    init(
        id: UUID = UUID(),
        capturedAt: Date = .now,
        pathExtension: String = ImageDataFormat.jpeg.pathExtension,
        coordinate: CLLocationCoordinate2D? = nil
    ) {
        self.id = id
        self.capturedAt = capturedAt
        self.pathExtension = pathExtension
        latitude = coordinate?.latitude
        longitude = coordinate?.longitude
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
