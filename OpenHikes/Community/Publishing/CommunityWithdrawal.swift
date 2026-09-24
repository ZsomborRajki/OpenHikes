//
//  CommunityWithdrawal.swift
//  OpenHikes
//
//  What a hiker says to take their own published hike down, and the message
//  it turns into.
//
//  ## Why this exists
//
//  Both published pages promise the same thing, in the same words:
//
//  > **Removal.** To have a hike you shared taken down, email
//  > zsombor.rajki@gmail.com with enough detail to identify it. Removing the
//  > hike from your own device does not withdraw a submission you have
//  > already sent.
//
//  — `docs/privacy/index.html`, and again in `docs/terms/index.html`. The app
//  gave a hiker nothing to keep that promise with. Guideline 1.2's reporting
//  and blocking halves were both built and both reachable; this is the third
//  thing the terms commit to, and the one a reviewer can check against the app
//  in a minute.
//
//  ## Why it is ``CommunityReport``'s sibling rather than a new idea
//
//  Everything about the shape of that type was argued for on a screen with
//  the same constraints, and every argument holds here:
//
//  - **Mail rather than a record type.** Browsing is account-free, and a
//    public-database write is not. See ``CommunityReport``'s header.
//  - **The record names go in the body.** A takedown is a reviewer's delete
//    and a delete needs a record ID. Which is the whole point here: the two
//    names live only on the `Hike` row, so deleting the hike is what destroys
//    the one thing "enough detail to identify it" could mean.
//  - **Nothing claims a takedown happened.** The same distinction the share
//    sheet and the report sheet already keep between *sent* and *published*.
//
//  ## The one real difference
//
//  A report is always about a listing, so ``CommunityReport`` can take one. A
//  withdrawal is about the hiker's own `Hike`, which has a submission name
//  from the moment it is sent and a listing name only once a reviewer has
//  published it — see ``Hike/communityListingID``. So the listing is optional
//  here, and the message says which of the two states this is: a submission
//  still in the queue and a hike other people can already find are different
//  things to ask about, and the reviewer's work is different for each.
//
//  ## And the second thing a hiker can publish
//
//  ``Subject`` is why this type takes a `kind` rather than being copied. A
//  hiker who contributed photographs to somebody else's trail has published
//  something, so the promise quoted above covers it word for word — and the
//  request is the same request against a different pair of record types. What
//  changes is the two type names in the body and the sentence explaining what
//  deleting each one does; what does not change is anything at all about the
//  mechanism, which is why a second type would have been two copies of one
//  promise drifting apart.
//
//  The **hike is never named as a record to remove**, whichever kind this is.
//  A contribution is somebody else's trail with this hiker's pictures on it,
//  and a withdrawal must not read as a request to take that trail down.
//

import Foundation
import OpenHikesData

/// One hiker's request to take their own shared hike down, and the mail it
/// composes.
///
/// A value rather than a view model, and the whole of what
/// ``CommunityWithdrawalSheet`` has to say — so what a reviewer receives can
/// be asserted without a screen, exactly as `CommunityReportTests` does for
/// the other direction.
nonisolated struct CommunityWithdrawal: Equatable, Sendable {
    /// Which of the two things a hiker can publish this is about.
    enum Subject: Equatable, Sendable {
        /// A hike of their own: ``CommunitySchema/listingType`` and
        /// ``CommunitySchema/submissionType``.
        case hike
        /// Photographs they put on a trail that already existed:
        /// ``CommunitySchema/contributionType`` and
        /// ``CommunitySchema/photoSubmissionType``.
        case photographs

        /// What the reviewer deletes to unpublish it.
        var publishedType: String {
            switch self {
            case .hike: CommunitySchema.listingType
            case .photographs: CommunitySchema.contributionType
            }
        }

        /// What the reviewer deletes to remove the content behind it.
        var submissionType: String {
            switch self {
            case .hike: CommunitySchema.submissionType
            case .photographs: CommunitySchema.photoSubmissionType
            }
        }
    }

    /// Whether this is about a hike or about contributed photographs.
    var kind: Subject = .hike
    /// The submission record's name — ``Hike/communitySubmissionID`` for a
    /// hike, ``Hike/communityPhotoSubmissionID`` for photographs. Always
    /// present: there is nothing to withdraw without one.
    var submissionID: String
    /// The ``Hike/communityListingID``, when a reviewer has published it.
    /// `nil` while the submission is still in the queue.
    var listingID: String?
    /// ``Hike/displayTitle``, so a reviewer can recognise the hike before
    /// opening a console.
    var title: String
    /// When the hike was walked — the other half of "enough detail to
    /// identify it", and what tells two hikes with the same name apart.
    var hikeDate: Date
    /// What the hiker typed, or empty. Trimmed on the way in.
    var note: String

    init(
        submissionID: String,
        listingID: String?,
        title: String,
        hikeDate: Date,
        kind: Subject = .hike,
        note: String = ""
    ) {
        self.kind = kind
        self.submissionID = submissionID
        self.listingID = listingID
        self.title = title
        self.hikeDate = hikeDate
        self.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Built from the hiker's own row, or `nil` for a hike that was never
    /// sent — which is the state with nothing to ask about.
    init?(hike: Hike, note: String = "") {
        guard let sent = hike.communitySubmissionID else { return nil }
        self.init(
            submissionID: sent,
            listingID: hike.communityListingID,
            title: hike.displayTitle,
            hikeDate: hike.date,
            note: note
        )
    }

    /// Built from the hiker's own row, about the photographs they put on
    /// somebody else's trail — or `nil` when they never sent any.
    ///
    /// The title is still their own hike's, which is the right one: it is what
    /// they will call the walk when they write about it, and the reviewer
    /// finds the records by name rather than by the trail.
    init?(contributedPhotosOf hike: Hike, note: String = "") {
        guard let sent = hike.communityPhotoSubmissionID else { return nil }
        self.init(
            submissionID: sent,
            listingID: hike.communityPhotoContributionID,
            title: hike.displayTitle,
            hikeDate: hike.date,
            kind: .photographs,
            note: note
        )
    }

    /// Whether a reviewer has published this, which decides what they have to
    /// delete and what the hiker is told.
    var isPublished: Bool { listingID != nil }

    /// Whether this is about photographs rather than about a hike. What the
    /// sheet's own wording branches on.
    var isAboutPhotographs: Bool { kind == .photographs }

    /// Carries a record name so a reviewer scanning a mailbox can tell two
    /// requests apart before opening either — the listing's when there is one,
    /// since that is the record a published hike is found by, and the
    /// submission's otherwise.
    var subject: String {
        "OpenHikes removal request: \(listingID ?? submissionID)"
    }

    /// Everything the reviewer needs to find the hike and delete the right
    /// records.
    ///
    /// Not localized, for the reason ``CommunityReport/body`` is not: one
    /// person reads these, in one language, and a request arriving in a
    /// language they cannot read is one they cannot act on.
    var body: String {
        var lines = [
            Self.opening(kind: kind, isPublished: isPublished),
            "",
            kind == .hike ? "The hike" : "The walk the photos came from",
            "Title: \(title)",
            "Walked: \(CommunityReport.reviewerDate.string(from: hikeDate))",
            "Status: \(isPublished ? "published" : "awaiting review")",
        ]
        if !note.isEmpty {
            lines.append(contentsOf: ["", "From the hiker:", note])
        }
        lines.append(contentsOf: ["", "Records to remove"])
        if let listingID {
            lines.append("\(kind.publishedType): \(listingID)")
        }
        lines.append("\(kind.submissionType): \(submissionID)")
        lines.append("")
        lines.append(contentsOf: Self.closing(kind: kind, isPublished: isPublished))
        return lines.joined(separator: "\n")
    }

    /// The first line, which is the one a reviewer reads before deciding
    /// whether to open the console at all.
    private static func opening(kind: Subject, isPublished: Bool) -> String {
        switch (kind, isPublished) {
        case (.hike, true):
            "The hiker who shared this hike is asking for it to be taken down."
        case (.hike, false):
            "The hiker who sent this submission is asking to withdraw it."
        case (.photographs, true):
            """
            The hiker who contributed these photos is asking for them to be taken down. \
            The trail itself is somebody else's and is not part of this request.
            """
        case (.photographs, false):
            "The hiker who sent these photos is asking to withdraw them before review."
        }
    }

    /// What deleting each record actually does, so a reviewer acting on this
    /// does not have to remember which of the four types is which.
    private static func closing(kind: Subject, isPublished: Bool) -> [String] {
        let first = isPublished
            ? "Deleting the \(kind.publishedType) record unlists it; deleting the"
            : "There is no \(kind.publishedType) record yet. Deleting the"
        let second = switch kind {
        case .hike: "\(kind.submissionType) record removes the route and photographs behind it."
        case .photographs: "\(kind.submissionType) record removes the photographs behind it."
        }
        return [first, second]
    }

    /// The `mailto:` this opens, or `nil` if it could not be formed. Escaped
    /// by ``CommunityReport``'s own routine, so a note containing `&` or `=`
    /// cannot truncate this message either.
    var mailURL: URL? {
        CommunityReport.mailURL(subject: subject, body: body)
    }

    /// The whole message as one block, for the hiker to copy when there is no
    /// mail app to hand it to. Composed by ``CommunityReport``'s own routine,
    /// so both messages to the same inbox name it the same way.
    var plainText: String {
        CommunityReport.plainText(subject: subject, body: body)
    }
}
