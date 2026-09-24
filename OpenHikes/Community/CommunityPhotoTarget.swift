//
//  CommunityPhotoTarget.swift
//  OpenHikes
//
//  The hike a set of photographs is offered *to*, when the trail itself is
//  already in the community list.
//
//  This is the value that turns a refusal into an offer. Three of the four
//  things ``CommunityPublishingEligibility`` says no to are not really "no" at
//  all — they are "the route is already here":
//
//  - a hike saved from OpenStreetMap,
//  - a hike saved from somebody else's listing,
//  - a hike retracing one this hiker has already published.
//
//  In every one of those the hiker has walked a trail that other people can
//  already find, and has come back with the one thing that trail has not got.
//  A curated route carries **no photographs at all** — measured, not assumed:
//  zero `image` tags across 106 relations — and a published hike carries
//  whatever its author happened to take on the day. Refusing the pictures
//  along with the route threw away the only part of the upload that was new.
//
//  ## Why the target is a string rather than a listing
//
//  Because the two sources have to be aimable at identically, and only one of
//  them has a record. ``CommunityIdentity`` already solved this once for
//  ``Hike/importedFromListingID``: one namespace, where a CloudKit record name
//  and a curated `osm:r/<relation>` cannot be mistaken for each other. A
//  contribution keys on exactly that string, which is why an OpenStreetMap
//  trail — a relation nobody published, with nothing in the public database
//  standing for it — can be a target at all.
//
//  It is deliberately **not** a `CKRecord.Reference`. A reference has to point
//  at a record that exists, and the whole point of the curated half is that
//  none does.
//
//  ## What is *not* here
//
//  A route, a title the hiker may edit, a description, a distance. None of
//  those is this hiker's to send: the trail already has them, from whoever
//  published it or from OpenStreetMap. ``title`` below is carried for the one
//  job of naming the target on screen, and nothing writes it anywhere.
//

import Foundation
import OpenHikesData

/// The hike a photo contribution would be attached to.
///
/// `Identifiable` on ``listingID`` so the share form can be presented with
/// `.sheet(item:)`: the target is what that screen cannot be built without,
/// and a `Bool` beside a separately-held value is two things that can disagree
/// about which trail the pictures are going to.
nonisolated struct CommunityPhotoTarget: Equatable, Hashable, Identifiable, Sendable {
    var id: String { listingID }

    /// The listing's identity, in the one namespace both sources share: a
    /// CloudKit record name, or ``CommunityIdentity/curated(relationID:)``.
    ///
    /// Read off ``Hike/importedFromListingID`` for a saved trail, and off
    /// ``Hike/communityListingID`` for a hike this hiker published themselves.
    /// Both columns hold the same kind of value, which is what lets one
    /// contribution path serve all three cases.
    var listingID: String

    /// What the trail is called, for the sentence on the share form and the
    /// row in the reviewer's queue.
    ///
    /// A convenience and never a claim. The listing's own title is whatever
    /// the reviewer published it under, and a contribution cannot change it —
    /// this is the name the hiker's own copy of the hike carries, which is the
    /// name they will recognise.
    var title: String

    /// Who published the trail, when somebody did.
    ///
    /// `nil` for an OpenStreetMap route, which nobody published, and `nil`
    /// for the hiker's own hike, where naming them back to themselves would
    /// read as a stranger. Both absences are the same sentence on screen:
    /// there is no other person to mention.
    var authorName: String?

    /// Whether the trail these are joining is this hiker's own publication.
    ///
    /// Stored rather than derived, because it is the one fact about a target
    /// that cannot be read off the identity: a listing record name looks the
    /// same whoever published it, and ``authorName`` is `nil` for a hiker's
    /// own hike *and* for an OpenStreetMap route *and* for somebody who shared
    /// without a name. Three different absences, one of which changes what the
    /// form says.
    ///
    /// Two paths set it. A **retread** — walking a trail this hiker published
    /// earlier — and the hike that *is* the publication, which is how a
    /// photograph added after a hike went live reaches the listing it belongs
    /// on. Both end at the same place: the route is already there, under this
    /// hiker's own name, and a second upload of it would be the duplicate
    /// listing this whole gate exists to prevent.
    var isYours = false

    /// Whether the trail came from OpenStreetMap rather than from a hiker.
    ///
    /// Derived rather than stored, so it cannot disagree with ``listingID`` —
    /// the same rule ``CommunityListing/isCurated`` follows.
    var isCurated: Bool { CommunityIdentity.isCurated(listingID) }
}

nonisolated extension CommunityPhotoTarget {
    /// The hike's *own* listing, for a walk this hiker published and has since
    /// added photographs to.
    ///
    /// The case this type was missing, and the one a hiker hits most: they
    /// shared a walk, came home, added the pictures off the camera, and tapped
    /// the same button again. What that button used to offer was *Share
    /// Again*, which cannot amend a submission — by ``CommunitySchema``'s
    /// design, since an amendable submission is an approved record that can be
    /// swapped after approval — so it made a **second** listing of the same
    /// trail and pointed the hike at it, leaving the first one live and
    /// findable. Two rows for one walk, and the first of them the one with the
    /// reviews.
    ///
    /// So the photographs go on as a contribution to the listing that is
    /// already there, which is the one shape this schema has for adding
    /// anything to a published hike. It reads a little oddly from the inside —
    /// the hiker is credited on their own trail — and that is the honest
    /// account of what happened: the walk was published in June and these
    /// pictures arrived in September, which is exactly what a contribution
    /// records.
    ///
    /// - Parameter listingID: ``Hike/communityListingID``, which is non-`nil`
    ///   exactly when ``CommunityPublicationState/published`` is the answer.
    ///   `nil` here means the hike is not published, and there is nothing to
    ///   add to.
    static func published(listingID: String?, title: String) -> Self? {
        guard let listingID else { return nil }
        // No author name, for the reason the retread path passes none: naming
        // the hiker back to themselves reads as a stranger.
        return Self(listingID: listingID, title: title, authorName: nil, isYours: true)
    }
}
