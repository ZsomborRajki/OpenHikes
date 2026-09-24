//
//  CommunityWithdrawalTests.swift
//  OpenHikesTests
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import Testing

/// What a reviewer actually receives when a hiker asks for their own hike
/// back.
///
/// `CommunityReportTests`' mirror, and asserted the same way and for the same
/// reason: the message leaves the device inside somebody else's mail app, so a
/// field missing from it is discovered by a reviewer who cannot act.
///
/// The record names carry more weight here than they do in a report. A report
/// is about a listing the app is looking at; a withdrawal is about a hike
/// whose two record names live on one `Hike` row and nowhere else — so this is
/// the last moment they can be read at all.
@Suite("Community withdrawal")
struct CommunityWithdrawalTests {
    private static let walked = Date(timeIntervalSince1970: 1_700_000_000)

    private static func withdrawal(
        submissionID: String = "submission-42",
        listingID: String? = "listing-42",
        title: String = "Ben Nevis",
        kind: CommunityWithdrawal.Subject = .hike,
        note: String = ""
    ) -> CommunityWithdrawal {
        CommunityWithdrawal(
            submissionID: submissionID,
            listingID: listingID,
            title: title,
            hikeDate: walked,
            kind: kind,
            note: note
        )
    }

    // MARK: - What the reviewer can act on

    /// The point of the whole feature: `docs/privacy` and `docs/terms` ask for
    /// "enough detail to identify it", and these two names are the only thing
    /// that is ever enough.
    @Test("a published hike's request names both records")
    func publishedNamesBothRecords() {
        let body = Self.withdrawal().body

        #expect(body.contains("CommunityHike: listing-42"))
        #expect(body.contains("CommunityHikeSubmission: submission-42"))
    }

    /// There is no listing record yet, so naming one would send a reviewer
    /// looking for something that does not exist.
    @Test("a submission still in the queue names only the submission")
    func awaitingReviewNamesOnlyTheSubmission() {
        let body = Self.withdrawal(listingID: nil).body

        #expect(body.contains("CommunityHikeSubmission: submission-42"))
        #expect(!body.contains("CommunityHike: "))
        #expect(body.contains("no CommunityHike record yet"))
    }

    /// The two states are different work for a reviewer — one is a delete of
    /// two records, the other of one — so the message says which it is rather
    /// than leaving it to be inferred from what is listed.
    @Test("the request says which state the hike is in", arguments: [
        ("listing-42", "published"),
        (nil, "awaiting review"),
    ])
    func statusIsStated(listingID: String?, expected: String) {
        #expect(Self.withdrawal(listingID: listingID).body.contains("Status: \(expected)"))
    }

    /// The subject alone has to distinguish two requests in a mailbox. A
    /// published hike is found by its listing; one still in the queue has only
    /// its submission to be named by.
    @Test("the subject identifies the hike without being opened", arguments: [
        ("listing-42", "listing-42"),
        (nil, "submission-42"),
    ])
    func subjectIdentifiesTheHike(listingID: String?, expected: String) {
        #expect(Self.withdrawal(listingID: listingID).subject.contains(expected))
    }

    /// The other half of "enough detail to identify it", and what tells two
    /// hikes with the same name apart.
    @Test("the request carries the title and the date walked")
    func carriesTitleAndDate() {
        let body = Self.withdrawal(title: "Ben Nevis").body

        #expect(body.contains("Title: Ben Nevis"))
        #expect(body.contains("2023-11-14"))
    }

    @Test("what the hiker typed reaches the reviewer")
    func noteReachesTheReviewer() {
        let body = Self.withdrawal(note: "My daughter is in two of the photos").body

        #expect(body.contains("My daughter is in two of the photos"))
    }

    /// A blank note is not a note — the same empty heading
    /// `CommunityReportTests` guards against.
    @Test("a blank note leaves no empty heading behind")
    func blankNoteIsOmitted() {
        #expect(!Self.withdrawal(note: "  \n ").body.contains("From the hiker"))
    }

    /// Nothing in the message may describe this as done. The app cannot delete
    /// a public record, and the whole shape of this feature — like the share
    /// sheet and the report sheet — keeps *asked* apart from *happened*.
    @Test("nothing claims the hike has been taken down")
    func claimsNothing() {
        let body = Self.withdrawal().body.lowercased()

        #expect(body.contains("asking"))
        #expect(!body.contains("has been removed"))
        #expect(!body.contains("was taken down"))
    }

    // MARK: - The mailto:

    @Test("the composed mail goes to the published address")
    func mailIsAddressedToTheReviewer() throws {
        let url = try #require(Self.withdrawal().mailURL)

        #expect(url.scheme == "mailto")
        #expect(url.absoluteString.hasPrefix("mailto:\(CommunityReport.recipient)?"))
    }

    /// The escaping is shared with `CommunityReport` rather than restated, and
    /// this is what holds it to that: a note containing `&` or `=` would
    /// otherwise end the body early and the request would arrive truncated.
    @Test("a note containing & or = does not truncate the body")
    func queryDelimitersInTheNoteAreEscaped() throws {
        let note = "Photo 2 & photo 3 = my front door"
        let url = try #require(Self.withdrawal(note: note).mailURL)
        let query = try #require(url.query(percentEncoded: false))

        #expect(url.absoluteString.contains("%26"))
        #expect(query.contains(note))
    }

    /// A title is the hiker's own typing and can hold anything. The URL has to
    /// be formable regardless, because the fallback for one that is not is the
    /// hiker copying the request out by hand.
    @Test("an awkward title still composes a mail")
    func awkwardTitleStillComposes() throws {
        let url = try #require(
            Self.withdrawal(title: "Ridge #4 — 100% up & over?").mailURL
        )

        #expect(url.scheme == "mailto")
    }

    // MARK: - The fallback

    /// What a hiker with no mail app copies. It is useless without the
    /// address, and worse than useless without the record names: those are the
    /// part they cannot retype from memory.
    @Test("the copyable fallback carries the address and the record names")
    func fallbackCarriesEverything() {
        let text = Self.withdrawal().plainText

        #expect(text.contains(CommunityReport.recipient))
        #expect(text.contains("listing-42"))
        #expect(text.contains("submission-42"))
    }

    // MARK: - The other thing a hiker can publish

    /// A hiker who contributed photographs to somebody else's trail has
    /// published something, so the promise both published pages make covers it
    /// word for word. What changes is which pair of records a reviewer has to
    /// delete — and a request naming the hike's two would be a request to take
    /// down a trail nobody asked about.
    @Test("a photo withdrawal names the contribution's records and not a hike's")
    func photoWithdrawalNamesItsOwnRecords() {
        let body = Self.withdrawal(
            submissionID: "photo-submission-9",
            listingID: "contribution-9",
            kind: .photographs
        ).body

        #expect(body.contains("\(CommunitySchema.contributionType): contribution-9"))
        #expect(body.contains("\(CommunitySchema.photoSubmissionType): photo-submission-9"))
        // Neither of the hike's two types is named anywhere, which is the
        // half that matters: the trail is somebody else's.
        #expect(!body.contains(CommunitySchema.listingType))
        #expect(!body.contains(CommunitySchema.submissionType))
    }

    /// And the sentence says so, because a reviewer reading this in a mailbox
    /// decides what to open before they read the record names.
    @Test("a photo withdrawal says the trail is not part of the request")
    func photoWithdrawalSpareTheTrail() {
        let published = Self.withdrawal(kind: .photographs).body
        #expect(published.contains("not part of this request"))

        // Before review there is nothing published to unlist, and the opening
        // line has to be a different sentence: *withdraw* rather than *take
        // down*.
        let waiting = Self.withdrawal(listingID: nil, kind: .photographs).body
        #expect(waiting.contains("withdraw"))
        #expect(waiting.contains("There is no \(CommunitySchema.contributionType) record yet"))
    }

    /// Built from the hiker's own row, and `nil` for a hike that never
    /// contributed anything — which is the state with nothing to ask about,
    /// exactly as it is for a hike that was never shared.
    @Test("a hike that contributed nothing has nothing to withdraw")
    @MainActor
    func nothingContributedIsNothingToAskAbout() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        #expect(CommunityWithdrawal(contributedPhotosOf: hike) == nil)

        hike.communityPhotoSubmissionID = "photo-submission-9"
        let waiting = try #require(CommunityWithdrawal(contributedPhotosOf: hike))
        #expect(waiting.kind == .photographs)
        #expect(waiting.isAboutPhotographs)
        #expect(!waiting.isPublished)

        hike.communityPhotoContributionID = "contribution-9"
        let live = try #require(CommunityWithdrawal(contributedPhotosOf: hike))
        #expect(live.isPublished)
        #expect(live.subject.contains("contribution-9"))
    }

    /// The two conversations do not cross. A hike that has both shared its own
    /// route and contributed photographs to a different trail has two
    /// withdrawals to make, and each names its own pair.
    @Test("the two withdrawals a hike can make are about different records")
    @MainActor
    func theTwoWithdrawalsStayApart() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        hike.communitySubmissionID = "submission-1"
        hike.communityListingID = "listing-1"
        hike.communityPhotoSubmissionID = "photo-submission-9"
        hike.communityPhotoContributionID = "contribution-9"

        let own = try #require(CommunityWithdrawal(hike: hike))
        let photos = try #require(CommunityWithdrawal(contributedPhotosOf: hike))

        #expect(own.submissionID == "submission-1")
        #expect(own.listingID == "listing-1")
        #expect(photos.submissionID == "photo-submission-9")
        #expect(photos.listingID == "contribution-9")
    }
}
