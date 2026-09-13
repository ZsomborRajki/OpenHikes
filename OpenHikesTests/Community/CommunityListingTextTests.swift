//
//  CommunityListingTextTests.swift
//  OpenHikesTests
//
//  How far a published listing's text is trusted on the way in.
//
//  `CommunityRouteOutlineTests` makes this argument about the field beside
//  these two, and it applies word for word: what is being read is a record in
//  a **public** database, which is to say text a reviewer may have pasted by
//  hand and a modified client may have written on purpose. The outline is
//  refused outright when it is over budget. The strings were taken as they
//  came.
//
//  A title with no ceiling is a row with no ceiling — `CommunityHikeRow` gives
//  its subtitle `lineLimit(1)` and its title deliberately none, so one listing
//  could push every other one off the screen. They are bounded rather than
//  refused, because unlike a corrupt outline an over-long title still says
//  which hike this is.
//
//  A `CKRecord` built here reaches nothing: it is an in-memory object until
//  something saves it, and nothing here does. What is deliberately *not* done
//  is the fetch around it — see *A suite must never reach the real transport*
//  in the instructions.
//

import CloudKit
import CoreLocation
import Foundation
@testable import OpenHikes
import Testing

@Suite("Community listing text")
struct CommunityListingTextTests {
    private static func record(
        title: String = "Thumsee Loop",
        authorName: String = "Anna Kovacs",
        authorID: String = "_abc123"
    ) -> CKRecord {
        let record = CKRecord(recordType: CommunitySchema.listingType)
        record[CommunitySchema.Listing.submission] = CKRecord.Reference(
            recordID: CKRecord.ID(recordName: "submission-1"),
            action: .none
        )
        record[CommunitySchema.Listing.title] = title
        record[CommunitySchema.Listing.authorName] = authorName
        record[CommunitySchema.Listing.authorID] = authorID
        record[CommunitySchema.Listing.location] = CLLocation(latitude: 47.63, longitude: 12.86)
        return record
    }

    /// An ordinary listing is untouched. A bound a real record can feel is a
    /// bug rather than a limit.
    @Test("a listing that fits arrives unchanged")
    func ordinaryListingSurvives() throws {
        let listing = try #require(CommunityListing(record: Self.record()))

        #expect(listing.title == "Thumsee Loop")
        #expect(listing.authorName == "Anna Kovacs")
    }

    /// The row's title is the one with no `lineLimit`, so this is the bound
    /// that decides whether one listing can take the list.
    @Test("an over-long title is bounded rather than drawn")
    func titleIsBounded() throws {
        let sent = String(repeating: "T", count: TextBound.title.characters * 50)

        let listing = try #require(CommunityListing(record: Self.record(title: sent)))

        #expect(listing.title.count == TextBound.title.characters)
        #expect(sent.hasPrefix(listing.title))
    }

    /// The credit is bounded tighter, and on the same argument: it is drawn
    /// inside a single subtitle line beside a distance and a photo count.
    @Test("an over-long author name is bounded")
    func authorNameIsBounded() throws {
        let sent = String(repeating: "A", count: TextBound.credit.characters * 50)

        let listing = try #require(CommunityListing(record: Self.record(authorName: sent)))

        #expect(listing.authorName.count == TextBound.credit.characters)
    }

    /// A listing shared without a name still has an empty credit rather than
    /// an absent one — ``CommunityHikeRow`` leaves the "by …" clause out on
    /// `isEmpty`, and bounding must not change which answer that is.
    @Test("a blank author name stays blank")
    func blankAuthorNameStaysBlank() throws {
        let listing = try #require(CommunityListing(record: Self.record(authorName: "   ")))

        #expect(listing.authorName.isEmpty)
    }

    /// The drop rule is unchanged by any of this: a listing the reviewer
    /// published without an `authorID` is one nobody can block, and it is
    /// refused rather than bounded. Asserted here because bounding runs in the
    /// same initializer and must not have moved the guard above it.
    @Test("a listing with no author id is still dropped")
    func listingWithoutAuthorIDIsRefused() {
        #expect(CommunityListing(record: Self.record(authorID: "  ")) == nil)
    }
}
