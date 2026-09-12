//
//  CommunityPublicationCheckTests.swift
//  OpenHikesTests
//
//  What the app is allowed to conclude about its own submission, and how few
//  requests it spends concluding it.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import SwiftData
import Testing

@MainActor
@Suite("Community publication")
struct CommunityPublicationCheckTests {
    private static func listing(id: String = "listing-1") -> CommunityListing {
        CommunityListing(
            id: id,
            submissionID: "submission-1",
            title: "Pilis Ridge",
            authorName: "Anna",
            authorID: "author-1",
            hikeDate: .now,
            distanceMeters: 1000,
            photoCount: 0,
            latitude: 47.7,
            longitude: 18.9,
            publishedAt: .now
        )
    }

    // MARK: The three states

    /// The states are derived from two columns rather than stored as a third,
    /// so the only thing worth asserting is that they are read in the right
    /// order — and the interesting one is the last, where a listing outranks a
    /// missing submission id rather than being contradicted by it.
    @Test("a hike is unshared, waiting, or published — and never anything else")
    func statesFollowTheTwoColumns() {
        #expect(
            CommunityPublicationState(submissionID: nil, listingID: nil) == .notShared
        )
        #expect(
            CommunityPublicationState(submissionID: "s", listingID: nil) == .awaitingReview
        )
        #expect(
            CommunityPublicationState(submissionID: "s", listingID: "l") == .published
        )
        #expect(
            CommunityPublicationState(submissionID: nil, listingID: "l") == .published,
            "a listing is positive evidence; a missing submission id is only an absence"
        )
    }

    /// The duplicate guard the share form draws. Both states that have already
    /// sent something warn, because neither can be amended — a second share is
    /// a second hike in the list either way.
    @Test("sharing again would duplicate in both states that already sent one")
    func duplicateWarningCoversBothSentStates() {
        #expect(!CommunityPublicationState.notShared.wouldDuplicate)
        #expect(CommunityPublicationState.awaitingReview.wouldDuplicate)
        #expect(CommunityPublicationState.published.wouldDuplicate)
    }

    // MARK: The check

    @Test("a published submission is recorded on the hike")
    func publishedSubmissionIsRecorded() async throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        hike.communitySubmissionID = "submission-1"
        let transport = StubCommunityTransport()
        transport.publicationResult = .success(Self.listing())

        let changed = await CommunityPublicationCheck.refresh(hike, transport: transport)

        #expect(changed)
        #expect(hike.communityListingID == "listing-1")
        #expect(transport.recording.publicationChecks == ["submission-1"])
    }

    /// The ordinary state, and the one a hike spends most of its life in. It
    /// must not be mistaken for a refusal: nothing here may write anything
    /// that would let the screen say more than "waiting".
    @Test("no listing yet leaves the hike exactly as it was")
    func pendingSubmissionRecordsNothing() async throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        hike.communitySubmissionID = "submission-1"
        let transport = StubCommunityTransport()

        let changed = await CommunityPublicationCheck.refresh(hike, transport: transport)

        #expect(!changed)
        #expect(hike.communityListingID == nil)
        #expect(
            CommunityPublicationState(
                submissionID: hike.communitySubmissionID,
                listingID: hike.communityListingID
            ) == .awaitingReview
        )
    }

    /// A hike nobody has shared is not a question worth a round trip, and this
    /// runs on every detail screen that appears.
    @Test("an unshared hike costs no request")
    func unsharedHikeAsksNothing() async throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        let transport = StubCommunityTransport()

        let changed = await CommunityPublicationCheck.refresh(hike, transport: transport)

        #expect(!changed)
        #expect(transport.recording.publicationChecks.isEmpty)
    }

    /// Publication is one-way here — see `Hike.communityListingID`. A hike
    /// already known live must not pay for a request on every appearance to
    /// re-learn something that cannot change back.
    @Test("a hike already known published is never asked about again")
    func publishedHikeIsNotRechecked() async throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        hike.communitySubmissionID = "submission-1"
        hike.communityListingID = "listing-1"
        let transport = StubCommunityTransport()

        let changed = await CommunityPublicationCheck.refresh(hike, transport: transport)

        #expect(!changed)
        #expect(transport.recording.publicationChecks.isEmpty)
    }

    /// This runs because a screen appeared, not because anybody asked. An
    /// offline phone opening a hike it shared last week has to go on showing
    /// what it showed before, silently.
    @Test("a failed check changes nothing and raises nothing")
    func failedCheckIsSilent() async throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        hike.communitySubmissionID = "submission-1"
        let transport = StubCommunityTransport()
        transport.publicationResult = .failure(.unreachable)

        let changed = await CommunityPublicationCheck.refresh(hike, transport: transport)

        #expect(!changed)
        #expect(hike.communityListingID == nil)
    }

    /// The listing is real whether or not the device managed to remember it,
    /// so a refused commit costs a repeated check and nothing else — the same
    /// reasoning `CommunityPublisher` applies to a refused commit after an
    /// upload that landed.
    @Test("a refused local commit still leaves the listing known in memory")
    func refusedCommitKeepsTheAnswer() async throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        hike.communitySubmissionID = "submission-1"
        let transport = StubCommunityTransport()
        transport.publicationResult = .success(Self.listing())

        let changed = await CommunityPublicationCheck.refresh(
            hike,
            transport: transport,
            save: { _ in throw CocoaError(.fileWriteNoPermission) }
        )

        #expect(changed)
        #expect(hike.communityListingID == "listing-1")
    }
}
