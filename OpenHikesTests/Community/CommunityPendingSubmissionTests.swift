//
//  CommunityPendingSubmissionTests.swift
//  OpenHikesTests
//
//  "Pending submissions", split out of CommunityReviewQueueTests.swift so
//  that a file declares one @Suite.
//

import Foundation
@testable import OpenHikes
import Testing

/// What a queue entry says publishing it would write.
///
/// Separate from the suite above because it is about a value rather than a
/// lifecycle, and because what it pins is the property the whole review path
/// rests on: the listing a reviewer approves is assembled from what they were
/// shown, not re-read from a record afterwards.
@Suite("Pending submissions")
struct CommunityPendingSubmissionTests {
    @Test("the prospective listing carries what publishing writes")
    func prospectiveListingCarriesThePublishedFields() {
        let pending = CommunityPendingSubmission.stub(
            id: "notice-7",
            submissionID: "submission-7",
            title: "Pilis Ridge",
            authorName: "Anna",
            authorID: "author-7",
            distanceMeters: 8000,
            latitude: 47.63,
            longitude: 12.86
        )

        let listing = pending.prospectiveListing

        #expect(listing.submissionID == "submission-7")
        #expect(listing.title == "Pilis Ridge")
        #expect(listing.authorName == "Anna")
        #expect(listing.blockableAuthorID == "author-7")
        #expect(listing.distanceMeters == 8000)
        #expect(listing.latitude == 47.63)
        #expect(listing.longitude == 12.86)
        #expect(listing.hikeDate == pending.hikeDate)
    }

    /// The one field that is *not* a listing's. It is the notice's record
    /// name, because there is no listing yet — see
    /// ``CommunityPendingSubmission``'s header for what that identity may and
    /// may not be used for.
    @Test("the prospective listing's id is the queue entry's, not a listing's")
    func prospectiveListingIdentityIsTheNotice() {
        let pending = CommunityPendingSubmission.stub(
            id: "notice-7",
            submissionID: "submission-7"
        )

        #expect(pending.prospectiveListing.id == "notice-7")
        #expect(pending.prospectiveListing.id != pending.submissionID)
    }

    /// The count arrives with the photographs and cannot be known before them,
    /// so the transport reports zero and the screen that fetches them fills it
    /// in. A listing claiming photographs it has not got opens an empty
    /// gallery.
    @Test("a queue entry starts with no photo count")
    func queueEntriesStartWithNoPhotoCount() {
        #expect(CommunityPendingSubmission.stub().photoCount == 0)
    }
}
