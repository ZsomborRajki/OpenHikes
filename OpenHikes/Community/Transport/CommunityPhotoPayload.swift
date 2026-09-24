//
//  CommunityPhotoPayload.swift
//  OpenHikes
//
//  The `Sendable` values a set of contributed photographs travels as: up to
//  the public database, through a reviewer's queue, and back down onto the
//  hike it belongs to.
//
//  The shapes deliberately mirror ``CommunityPayload``'s, one for one —
//  ``CommunityPhotoDraft`` is ``CommunitySubmissionDraft`` with the route and
//  the prose taken out, ``CommunityPendingPhotos`` is
//  ``CommunityPendingSubmission`` with the same, and
//  ``CommunityPhotoContribution`` is what ``CommunityListing`` is to a hike.
//  That parallel is worth keeping: a reader who has understood one half of
//  this feature has understood both, and the two halves share a queue, a
//  staging directory, a cap and a re-encode.
//
//  What they do **not** share is a record type. A contribution is its own
//  submission and its own published record, with its own creator, and that is
//  the whole design rather than an implementation detail — see
//  ``CommunitySchema``. Appending a stranger's photographs onto the hike
//  author's submission would have been cheaper on every read path and wrong
//  on three counts: it would publish one person's pictures under another
//  person's name, it would rewrite a record the browse path is already
//  serving — the write-once rule the schema exists for — and it could not be
//  done at all for an OpenStreetMap trail, which has no submission to append
//  to.
//
//  ## Why a contribution carries its own author
//
//  Because everything Guideline 1.2 asks for keys on it. A contributed
//  photograph is user-generated content by somebody other than the hike's
//  author, so blocking the author must not hide it and must not fail to hide
//  the person who actually sent it. ``CommunityBlockList`` is keyed on the
//  creator CloudKit stamps, and this is that creator — the same field,
//  carried the same way, for the same reason.
//

import CoreLocation
import Foundation
import OpenHikesData

/// A set of photographs offered to a hike that already exists, ready to
/// upload.
///
/// The photographs are file URLs rather than `Data` for the reason
/// ``CommunitySubmissionDraft``'s are: CloudKit takes an asset as a file and
/// streams it from there, and the re-encoded copies have to be written
/// somewhere regardless.
nonisolated struct CommunityPhotoDraft: Sendable {
    /// The hike these belong to.
    var target: CommunityPhotoTarget
    /// The hiker's own copy of the walk, so the staging directory can be named
    /// per attempt the way a share's is.
    var hikeID: UUID
    /// What to publish them under — the hiker's own words, the same
    /// ``SettingsKey/communityAuthorName`` a shared hike is credited with.
    var authorName: String
    /// The day the photographs were taken, which is the hike's date.
    ///
    /// Carried for the reviewer rather than for the gallery: each picture
    /// already has its own capture time in ``photoPins``, and this is the one
    /// figure a queue row can show without downloading anything.
    var takenOn: Date
    /// Where each photograph was taken, in ``photoFileURLs`` order.
    var photoPins: [CommunityPhotoPin]
    /// The re-encoded copies, staged under ``stagingDirectory``.
    var photoFileURLs: [URL]
    /// The directory the publisher created for this attempt and deletes on
    /// every exit. See ``CommunityStaging``.
    var stagingDirectory: URL

    /// Where on the trail these pictures were taken, as one point.
    ///
    /// The first anchored photograph rather than a centroid, and that is the
    /// honest choice: a centroid of pictures taken along a valley walk is a
    /// point on a hillside nobody stood on, and what this is for is standing
    /// the reviewer's map somewhere the photographs actually are. `nil` when
    /// no picture knows where it was taken, which is a contribution a reviewer
    /// judges on the pictures alone.
    var startCoordinate: CLLocationCoordinate2D? {
        photoPins.lazy.compactMap(\.coordinate).first
    }
}

/// A contribution waiting for a person to look at it.
///
/// One of the two kinds of row in the reviewer's queue — see
/// ``CommunityReviewBatch``. It carries the fields the published record needs
/// for the reason ``CommunityPendingSubmission`` does: **what the reviewer saw
/// is what gets published**, rather than re-reading the submission after the
/// decision.
nonisolated struct CommunityPendingPhotos: Identifiable, Hashable, Sendable {
    /// The *notice* record's name, which is this queue entry's identity and
    /// what publishing or declining deletes.
    var id: String
    /// The `CommunityPhotoSubmission` record the pictures are on.
    var photoSubmissionID: String
    /// The listing these are aimed at, in ``CommunityIdentity``'s namespace.
    var listingID: String
    /// What the hiker typed as a credit, which may be empty.
    var authorName: String
    /// The submission's creator, as CloudKit knows them. Never shown, and the
    /// thing a block is keyed on.
    var authorID: String
    var takenOn: Date
    /// How many photographs went with it.
    ///
    /// Zero until the review screen fetches them, exactly as
    /// ``CommunityPendingSubmission/photoCount`` is and for the same reason:
    /// the count arrives with the assets, and the queue is read with
    /// `desiredKeys` that deliberately leave them out.
    var photoCount: Int
    var latitude: Double
    var longitude: Double
    /// When the notice reached the queue, stamped by the server.
    var noticedAt: Date

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// Whether these are offered to an OpenStreetMap route rather than to a
    /// hike somebody published.
    var isCurated: Bool { CommunityIdentity.isCurated(listingID) }

    /// The listing the review screen hands the map, so a contribution's pins
    /// can be drawn the way a submission's route is.
    ///
    /// The same trick ``CommunityPendingSubmission/prospectiveListing`` plays
    /// and with the same warning: its ``CommunityListing/id`` is a queue
    /// entry's identity rather than a listing's, which is right for telling
    /// two open previews apart and wrong for anything meaning "the published
    /// record this came from". Nothing in the photo review path asks that.
    ///
    /// The distance is zero and the title is the hiker's credit, because
    /// neither is a fact this record carries — a contribution is photographs
    /// and nothing else. Nothing draws a row from this; it exists for
    /// ``CommunityBrowser/previewPhotosLoaded(_:of:)``, which needs a listing
    /// to key on and reads nothing else off it.
    var prospectiveListing: CommunityListing {
        CommunityListing(
            id: id,
            submissionID: photoSubmissionID,
            title: authorName,
            authorName: authorName,
            authorID: authorID,
            hikeDate: takenOn,
            distanceMeters: 0,
            photoCount: photoCount,
            latitude: latitude,
            longitude: longitude,
            publishedAt: noticedAt
        )
    }
}

/// Photographs somebody other than the hike's author published onto it,
/// downloaded and ready to draw.
///
/// One value per *contribution*, not per photograph, because the credit, the
/// author and the two record names are facts about the set: they are what a
/// report names, what a block is keyed on, and what a takedown deletes.
nonisolated struct CommunityPhotoContribution: Identifiable, Hashable, Sendable, CommunityReviewSubject {
    /// The `CommunityPhotoContribution` record's name — what a takedown
    /// deletes and what a report quotes.
    var id: String
    /// The `CommunityPhotoSubmission` behind it, which holds the assets. The
    /// second record name a takedown needs.
    var photoSubmissionID: String
    /// What the contributor asked to be credited as, which may be empty.
    var authorName: String
    /// The creator CloudKit stamped on the submission. Never shown, and what
    /// ``CommunityBlockList`` keys on.
    var authorID: String
    /// When a reviewer published it. The gallery's order after the hike's own
    /// photographs, oldest first, so a set does not move under a hiker who
    /// scrolls back.
    var publishedAt: Date
    /// Where each photograph was taken, in ``photoFileURLs`` order.
    var photoPins: [CommunityPhotoPin]
    /// The downloaded copies, owned by the screen that asked for them.
    var photoFileURLs: [URL]
    /// How many photographs the submission actually carries.
    ///
    /// Here for the one reason ``CommunityHikeDetail/photosOnRecord`` is here:
    /// a screen that **rewrites** the record's photographs builds the rewrite
    /// out of the copies on this device, so doing it with one missing would
    /// delete that one too. A screen merely showing a set has no use for it.
    var photosOnRecord: Int = 0

    /// Who these photographs belong to, carried onto every one of them.
    ///
    /// The four fields are meaningful only together — a credit with no author
    /// id is a photograph nobody can block — which is why they travel as one
    /// value. See ``CommunityPhotoAttribution``.
    var galleryAttribution: CommunityPhotoAttribution? {
        CommunityPhotoAttribution(
            contributionID: id,
            photoSubmissionID: photoSubmissionID,
            credit: credit,
            authorID: authorID
        )
    }

    /// What to put beside a photograph from this set, or `nil` when the
    /// contributor asked for no credit.
    var credit: String? {
        authorName.isEmpty ? nil : authorName
    }

    /// ``CommunityReviewSubject``'s spelling, numbered from zero: on a review
    /// screen there is nothing before these — a contribution under review is
    /// not sitting after a hike's own pictures the way it will be once it is
    /// published.
    var reviewPreviewPhotos: [CommunityPreviewPhoto] { previewPhotos(startingAt: 0) }
}

/// Who a contributed photograph belongs to, and the two record names that
/// stand for it.
///
/// Carried on every gallery photograph that came from a contribution and
/// absent on every one that came from the hike's own author, which is what
/// makes the per-photograph menu possible: a credit to draw, an author to
/// block, and the pair of names a report or a takedown has to quote. See
/// ``CommunityGalleryPhoto/contribution``.
///
/// Its own value rather than four optional fields on the photograph, because
/// the four are meaningful only together — a credit with no author id is a
/// photograph nobody can block, which is the state
/// ``CloudKitCommunityTransport/ContributionRecord`` refuses to build.
nonisolated struct CommunityPhotoAttribution: Equatable, Hashable, Sendable {
    /// The published contribution record's name — what a takedown deletes.
    var contributionID: String
    /// The submission behind it — the second name a takedown and a report
    /// need.
    var photoSubmissionID: String
    /// What to show beside the picture, or `nil` for a contributor who asked
    /// for no credit.
    var credit: String?
    /// The contributor, as CloudKit knows them. Never shown; what a block is
    /// keyed on.
    var authorID: String
}
