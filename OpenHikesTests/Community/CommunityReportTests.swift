//
//  CommunityReportTests.swift
//  OpenHikesTests
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import Testing

/// What a reviewer actually receives when a hiker reports a published hike.
///
/// Asserted against the composed message rather than against the screen,
/// because the screen is the part that can be looked at and the message is the
/// part that cannot: it leaves the device inside somebody else's mail app, and
/// a field missing from it is discovered by a reviewer who cannot act on a
/// report inside the 24 hours the app promises.
///
/// The record names carry most of the weight here. A takedown is a delete, and
/// a delete needs an ID — see ``CommunityReport``.
@Suite("Community reporting")
struct CommunityReportTests {
    private static func report(
        reason: CommunityReportReason = .objectionable,
        note: String = "",
        listing: CommunityListing = .stub(),
        contribution: CommunityPhotoAttribution? = nil
    ) -> CommunityReport {
        CommunityReport(
            listing: listing,
            reason: reason,
            contribution: contribution,
            note: note
        )
    }

    /// A trail OpenStreetMap already had, which has no records of its own for
    /// a takedown to name.
    private static func curatedListing(relationID: Int64) -> CommunityListing {
        CommunityListing(
            id: CommunityIdentity.curated(relationID: relationID),
            origin: .openStreetMap(
                relationID: relationID,
                facts: CuratedTrailFacts(tags: ["name": "Soleleitensteig"], route: [])
            ),
            title: "Soleleitensteig",
            authorName: "",
            hikeDate: nil,
            distanceMeters: 6200,
            photoCount: 0,
            latitude: 47.6,
            longitude: 12.8,
            publishedAt: Date(timeIntervalSince1970: 1_750_000_000)
        )
    }

    /// One contributed set, for the reports that are about a photograph rather
    /// than about the hike it is on.
    private static let contribution = CommunityPhotoAttribution(
        contributionID: "contribution-9",
        photoSubmissionID: "photo-submission-9",
        credit: "Cass",
        authorID: "author-cass"
    )

    // MARK: - What the reviewer can act on

    @Test("the report names both records a takedown has to delete")
    func reportCarriesBothRecordNames() {
        let report = Self.report(
            listing: .stub(id: "listing-42", submissionID: "submission-42")
        )

        #expect(report.body.contains("CommunityHike: listing-42"))
        #expect(report.body.contains("CommunityHikeSubmission: submission-42"))
    }

    /// The subject alone has to distinguish two reports in a mailbox, because
    /// that is what a reviewer triaging them sees first.
    @Test("the subject identifies the listing without being opened")
    func subjectIdentifiesTheListing() {
        #expect(Self.report(listing: .stub(id: "listing-42")).subject.contains("listing-42"))
    }

    @Test("the report says what it was reported for")
    func reportNamesTheReason() {
        let report = Self.report(reason: .privacy)

        #expect(report.body.contains(CommunityReportReason.privacy.reportedDescription))
    }

    @Test("what the hiker typed reaches the reviewer")
    func noteReachesTheReviewer() {
        let report = Self.report(reason: .other, note: "The third photo shows a house number")

        #expect(report.body.contains("The third photo shows a house number"))
    }

    /// A blank note is not a note. Without this the body carries an empty
    /// "From the reporter:" heading, which reads as a complaint nobody wrote.
    @Test("a blank note leaves no empty heading behind")
    func blankNoteIsOmitted() {
        #expect(!Self.report(note: "   \n  ").body.contains("From the reporter"))
    }

    /// The author's name identifies who published the hike, and a blank one is
    /// a legitimate share — see `CommunityShareSheet`'s name field, which may
    /// be left empty. It must not reach the reviewer as an empty line.
    @Test("an unnamed author is said rather than left blank")
    func unnamedAuthorIsStated() {
        let report = Self.report(listing: .stub(authorName: ""))

        #expect(report.body.contains("Shared by: (no name given)"))
    }

    // MARK: - The mailto:

    @Test("the composed mail goes to the published address")
    func mailIsAddressedToTheReviewer() throws {
        let url = try #require(Self.report().mailURL)

        #expect(url.scheme == "mailto")
        #expect(url.absoluteString.hasPrefix("mailto:\(CommunityReport.recipient)?"))
    }

    /// The whole reason the URL is built by hand. `URLComponents` treats `&`
    /// and `=` as legal in a query component and leaves them alone, so a note
    /// containing either would end the body early — and the complaint would
    /// arrive truncated at exactly the character the hiker typed.
    @Test("a note containing & or = does not truncate the body")
    func queryDelimitersInTheNoteAreEscaped() throws {
        let note = "Photo 2 & photo 3 = the same house"
        let url = try #require(Self.report(reason: .privacy, note: note).mailURL)
        let query = try #require(url.query(percentEncoded: false))

        #expect(url.absoluteString.contains("%26"))
        #expect(query.contains(note))
    }

    /// Several mail clients still decode `+` in a query as a space, so a
    /// route description carrying one would reach the reviewer altered.
    @Test("a plus sign survives the trip")
    func plusSignIsEscaped() throws {
        let url = try #require(Self.report(note: "3+ hours out").mailURL)

        #expect(url.absoluteString.contains("%2B"))
        #expect(!url.absoluteString.contains("3+ hours"))
    }

    /// A title is somebody else's typing and can hold anything. The URL has to
    /// be formable regardless, because the fallback for one that is not is the
    /// hiker copying the report out by hand.
    @Test("an awkward title still composes a mail")
    func awkwardTitleStillComposes() throws {
        let listing = CommunityListing.stub(title: "Ridge #4 — 100% up & over?")
        let url = try #require(Self.report(listing: listing).mailURL)

        #expect(url.scheme == "mailto")
    }

    // MARK: - The fallback

    /// What a hiker with no mail app copies. It is useless without the
    /// address, which the composed `mailto:` carried for them.
    @Test("the copyable fallback carries the address and the record names")
    func fallbackCarriesEverything() {
        let text = Self.report(listing: .stub(id: "listing-42")).plainText

        #expect(text.contains(CommunityReport.recipient))
        #expect(text.contains("listing-42"))
    }

    // MARK: - The reasons

    /// Every case has to be both pickable and readable out of context: the
    /// hiker sees ``CommunityReportReason/title`` in a list and the reviewer
    /// sees ``CommunityReportReason/reportedDescription`` alone in an inbox.
    @Test("every reason is worded for both readers", arguments: CommunityReportReason.allCases)
    func everyReasonIsWorded(reason: CommunityReportReason) {
        #expect(!reason.title.isEmpty)
        #expect(!reason.reportedDescription.isEmpty)
        #expect(Self.report(reason: reason).mailURL != nil)
    }

    /// The picker draws `pickerOrder` and not `allCases`, so a reason added to
    /// the enum and not to that list is a reason no hiker can ever choose —
    /// which nothing else here would notice, because every other assertion
    /// iterates `allCases`.
    @Test("the picker offers every reason, with Something Else last")
    func pickerOrderCoversEveryReason() {
        #expect(Set(CommunityReportReason.pickerOrder) == Set(CommunityReportReason.allCases))
        #expect(CommunityReportReason.pickerOrder.count == CommunityReportReason.allCases.count)
        #expect(CommunityReportReason.pickerOrder.last == .other)
    }

    // MARK: - Reporting one photograph rather than a hike

    /// The reason this whole variant exists: a contributed photograph is
    /// somebody else's picture on a third party's trail, so the two records a
    /// reviewer deletes are the contribution's. Pointing them at the hike's
    /// would be a report that takes down a trail nobody complained about.
    @Test("a photo report names the contribution's two records")
    func photoReportNamesTheContribution() {
        let body = Self.report(
            listing: .stub(id: "listing-42", submissionID: "submission-42"),
            contribution: Self.contribution
        ).body

        #expect(body.contains("\(CommunitySchema.contributionType): contribution-9"))
        #expect(body.contains("\(CommunitySchema.photoSubmissionType): photo-submission-9"))
        #expect(!body.contains("\(CommunitySchema.listingType): listing-42"))
        #expect(!body.contains("\(CommunitySchema.submissionType): submission-42"))
        #expect(body.contains("not part of this report"))
    }

    /// The hike is still named, because a reviewer has to be able to find the
    /// photograph — and the credit, because it is what a hiker recognises the
    /// picture's owner by.
    @Test("a photo report still says which hike and who added it")
    func photoReportNamesTheContextAndTheAuthor() {
        let body = Self.report(
            listing: .stub(id: "listing-42", title: "Almbachklamm"),
            contribution: Self.contribution
        ).body

        #expect(body.contains("Almbachklamm"))
        #expect(body.contains("Cass"))
        #expect(body.contains("A photo somebody added"))
    }

    /// A curated trail has no records at all, and a report about a photograph
    /// on one is still perfectly actionable: the contribution's two names are
    /// the whole of what a takedown needs. The hike-report path sends a
    /// reviewer upstream to OpenStreetMap instead, which is the right answer
    /// there and the wrong one here.
    @Test("a photo report on an OpenStreetMap trail names records, not an upstream link")
    func photoReportOnACuratedTrail() {
        let body = Self.report(
            listing: Self.curatedListing(relationID: 12_345),
            contribution: Self.contribution
        ).body

        #expect(body.contains("contribution-9"))
        #expect(!body.contains("openstreetmap.org"))
    }

    /// A reviewer scanning a mailbox tells two reports apart before opening
    /// either, so the subject names the record this one is about.
    @Test("the subject names the contribution rather than the hike")
    func photoReportSubject() {
        let report = Self.report(
            listing: .stub(id: "listing-42"),
            contribution: Self.contribution
        )
        #expect(report.subject.contains("contribution-9"))
        #expect(!report.subject.contains("listing-42"))
    }
}
