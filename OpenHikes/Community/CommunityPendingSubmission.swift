//
//  CommunityPendingSubmission.swift
//  OpenHikes
//
//  One entry in the reviewer's queue: a submission somebody has sent and
//  nobody has looked at yet.
//
//  ## Why this carries the listing's fields rather than a reference
//
//  Publishing is creating a ``CommunitySchema/listingType`` record out of a
//  submission, and every field on that record is denormalised — see
//  ``CommunitySchema/Listing``. So this type holds exactly those values, read
//  off the submission at the moment the queue was built, and
//  ``CommunityTransporting/publish(_:)`` writes them without going back to the
//  server for anything.
//
//  That is deliberate rather than convenient: **what the reviewer looked at is
//  what gets published.** Re-reading the submission at publication time would
//  open a window in which the record that was judged and the record that was
//  listed are different — which is the exact failure the write-once rule on
//  ``CommunitySchema/submissionType`` exists to close, reintroduced one layer
//  up. A submission cannot change under a reviewer today, and this type means
//  nothing has to rely on that.
//
//  ## Where ``authorID`` comes from, and why that matters
//
//  From the submission's `creatorUserRecordID`, which CloudKit stamps and no
//  client can set. Publishing by hand in the Console means copying it out of
//  *Created By* and typing it onto the listing, and forgetting costs the hike
//  entirely: ``CommunityListing/init(record:)`` drops a listing without one,
//  so the hike is published and invisible with nothing anywhere reporting a
//  problem. Carrying it here is what takes that failure off the table — the
//  field is read by the same code that reads the title, and a reviewer cannot
//  forget a thing they were never asked to do.
//
//  ## Why there is a ``prospectiveListing``
//
//  The map draws the route of whatever preview is open, and it does that
//  through ``CommunityBrowser/previewLoaded(_:of:)``, which is keyed on a
//  ``CommunityListing``. A pending submission has no listing yet, so this
//  builds the one publishing *would* write, with the notice's record name
//  standing in for the listing's. Its ``CommunityListing/id`` is therefore a
//  queue entry's identity and not a listing's, which is fine for drawing a
//  line and for telling two open previews apart, and is wrong for anything
//  that means "the published record this came from".
//
//  Nothing in the review path does that — there is no *Save*, no *Report* and
//  no ``Hike/importedFromListingID`` to write, because none of those are
//  things a reviewer does to a hike nobody can see yet. A reader adding one of
//  them to this screen later is the person this paragraph is for.
//

import CoreLocation
import Foundation

/// A submission waiting for a person to look at it.
///
/// Built by ``CommunityTransporting/reviewQueue()`` from a notice and
/// the submission it points at. The text fields are bounded on the way in, the
/// way ``CommunityListing/init(record:)`` bounds the same fields and for the
/// same reason: what is being read is a stranger's text off a public database,
/// and this screen renders it.
nonisolated struct CommunityPendingSubmission: Identifiable, Hashable, Sendable {
    /// The *notice* record's name, which is this queue entry's identity.
    ///
    /// Not the submission's and not a listing's. It is what
    /// ``CommunityTransporting/decline(_:)`` and
    /// ``CommunityTransporting/publish(_:)`` delete when they are done.
    var id: String
    /// The submission this is about — the record that is fetched to preview it
    /// and referenced by the listing if it is published.
    var submissionID: String
    var title: String
    /// What the hiker typed as a credit, which may be empty.
    var authorName: String
    /// The submission's creator, as CloudKit knows them. Never shown.
    var authorID: String
    /// What the hiker wrote about the walk, which is most of what there is to
    /// judge. Empty when they wrote nothing.
    var trackDescription: String
    var hikeDate: Date
    var distanceMeters: Double
    var photoCount: Int
    var latitude: Double
    var longitude: Double
    /// When the notice reached the queue, stamped by the server.
    ///
    /// `___createTime` rather than a field the client wrote, so nothing can
    /// backdate itself to the front of the queue.
    var noticedAt: Date

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// The listing publishing this would create.
    ///
    /// Used to draw the route on the map behind the review screen, which is
    /// keyed on a listing. See this file's header for what its
    /// ``CommunityListing/id`` is and what it is not.
    var prospectiveListing: CommunityListing {
        CommunityListing(
            id: id,
            submissionID: submissionID,
            title: title,
            authorName: authorName,
            authorID: authorID,
            hikeDate: hikeDate,
            distanceMeters: distanceMeters,
            photoCount: photoCount,
            latitude: latitude,
            longitude: longitude,
            publishedAt: noticedAt
        )
    }
}
