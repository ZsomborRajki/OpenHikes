//
//  CommonsPhoto.swift
//  OpenHikes
//
//  A photograph from Wikimedia Commons, standing on a curated route.
//
//  A route from OpenStreetMap has no photographs of its own — measured, zero
//  `image` tags on 106 hiking relations — and until somebody contributes one,
//  its preview had a line, a profile and no pictures, which is half of what a
//  hiker deciding on a trail looks at. Commons is where the pictures already
//  are: geotagged, openly licensed, and taken by people who stood on that
//  path. See ``CommonsPhotoQuery`` for what is asked and
//  ``CommonsTrailPhotos`` for which of the answers are kept.
//
//  This is the value the transport hands the preview, and the half of
//  ``CommunityHikeDetail`` the gallery, the map's pins and the import read it
//  through. It goes *after* everything people published on this app, in one
//  gallery numbered the way ``CommunityHikeDetail/galleryPhotos`` numbers the
//  rest, so a map pin, a strip tile and a gallery page agree about which
//  picture is which.
//

import CoreLocation
import Foundation
import OpenHikesData

/// One Wikimedia Commons photograph, downloaded and placed on a curated route.
nonisolated struct CommonsPhoto: Hashable, Sendable {
    /// Where the camera stood, snapped onto the route — the photograph's pin —
    /// and when the picture was taken.
    ///
    /// On the line rather than where Commons put it, for the reason a picked
    /// photograph is: a pin on the trail is a claim about *where along it*
    /// the picture belongs, and only cameras within
    /// ``CommonsTrailPhotos/corridorMeters`` of the line are kept to make it.
    var pin: CommunityPhotoPin
    /// The downloaded copy, in the directory the preview owns and deletes.
    var fileURL: URL
    var credit: CommonsPhotoCredit
}

/// Who took a Commons photograph, and what they shared it under.
///
/// Carried onto every gallery page and every saved copy, because the licence
/// is the only reason the app may show the picture at all — see
/// ``HikePhotoLicence``.
nonisolated struct CommonsPhotoCredit: Hashable, Sendable {
    /// The author as the file page names them, as text — or `nil` when it
    /// names nobody, and the source page is then the whole of the credit.
    var author: String?
    var licence: HikePhotoLicence
}

// MARK: - In the merged gallery

nonisolated extension CommunityHikeDetail {
    /// Where the Commons photographs start in the merged gallery: after the
    /// hike's own and after every contributed set.
    ///
    /// Last, because they are the only ones nobody published here. Counted
    /// over the **downloaded** files, as the contributed offsets are, because
    /// the gallery can only show what arrived and the index is a position in
    /// it.
    var commonsOffset: Int {
        contributions.reduce(photoFileURLs.count) { total, contribution in
            total + contribution.photoFileURLs.count
        }
    }

    /// The Commons photographs, for the map — every one of them, since each
    /// was kept for standing on the line.
    var commonsPreviewPhotos: [CommunityPreviewPhoto] {
        let offset = commonsOffset
        return commonsPhotos.enumerated().compactMap { index, photo in
            guard let coordinate = photo.pin.coordinate else { return nil }
            return CommunityPreviewPhoto(
                index: offset + index,
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                capturedAt: photo.pin.capturedAt,
                fileURL: photo.fileURL
            )
        }
    }

    /// The Commons photographs, for the strip and the gallery, each carrying
    /// its credit and licence.
    var commonsGalleryPhotos: [CommunityGalleryPhoto] {
        let offset = commonsOffset
        return commonsPhotos.enumerated().map { index, photo in
            CommunityGalleryPhoto(
                index: offset + index,
                pin: photo.pin,
                fileURL: photo.fileURL,
                contribution: nil,
                commons: photo.credit
            )
        }
    }
}
