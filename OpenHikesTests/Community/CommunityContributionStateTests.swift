//
//  CommunityContributionStateTests.swift
//  OpenHikesTests
//
//  Where a hike's *photographs* are on the trip from private to published, and
//  the one question the app can ask about them.
//
//  ``CommunityPublicationCheckTests`` asks these questions of a hike's own two
//  columns. This asks them of the other pair, and the reason both suites exist
//  rather than one is the reason both pairs of columns exist: *sent a hike*
//  and *sent some photographs to somebody else's hike* are different things a
//  hiker did, read by different controls, and a single pair holding either
//  would make **sent for review** ambiguous about what was sent.
//
//  What is pinned here is what the app is allowed to *say*. There are three
//  states and not four: a decline leaves no record, so the absence of a
//  published contribution covers a reviewer who has not looked and one who
//  said no. Anything claiming to tell those apart would be an observation
//  nothing supports.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import SwiftData
import Testing

@MainActor
@Suite("Community contribution state")
struct CommunityContributionStateTests {
    @Test("nothing sent is an offer")
    func notShared() {
        let state = CommunityContributionState(submissionID: nil, contributionID: nil)
        #expect(state == .notShared)
        #expect(!state.wouldDuplicate)
    }

    @Test("sent with no published record is waiting, and never rejected")
    func awaitingReview() {
        let state = CommunityContributionState(submissionID: "sub-1", contributionID: nil)
        #expect(state == .awaitingReview)
        #expect(state.wouldDuplicate)
    }

    @Test("a published contribution is live")
    func published() {
        let state = CommunityContributionState(submissionID: "sub-1", contributionID: "c-1")
        #expect(state == .published)
        #expect(state.wouldDuplicate)
    }

    /// Read published-first, for the reason ``CommunityPublicationState`` reads
    /// its listing first: the second column can only exist because of the
    /// first, so a row whose submission id was cleared while its published one
    /// stands is still a hiker whose pictures are on a trail — and reading the
    /// other way round would offer to send them again.
    @Test("a published record outranks a missing submission id")
    func publishedOutranksAClearedSubmission() {
        #expect(
            CommunityContributionState(submissionID: nil, contributionID: "c-1") == .published
        )
    }

    /// The check asks nothing for a hike that has sent nothing, and nothing
    /// for one already seen live. Both are the cheap cases and both are the
    /// common ones — almost every hike in a library has never contributed a
    /// photograph.
    @Test("a hike with nothing to ask about costs no request")
    func silentHikesAskNothing() async throws {
        let context = try Fixture.modelContext()
        let transport = StubCommunityTransport()

        let never = Fixture.hike(in: context, title: "Never contributed")
        #expect(await !CommunityContributionCheck.refresh(never, transport: transport))

        let live = Fixture.hike(in: context, title: "Already live")
        live.communityPhotoSubmissionID = "sub-1"
        live.communityPhotoContributionID = "c-1"
        #expect(await !CommunityContributionCheck.refresh(live, transport: transport))

        #expect(transport.recording.contributionChecks.isEmpty)
    }

    @Test("a waiting contribution is asked about once, and a yes is remembered")
    func aYesIsRemembered() async throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        hike.communityPhotoSubmissionID = "sub-1"
        let transport = StubCommunityTransport()
        transport.contributionResult = .success("contribution-9")

        #expect(await CommunityContributionCheck.refresh(hike, transport: transport))

        #expect(hike.communityPhotoContributionID == "contribution-9")
        #expect(transport.recording.contributionChecks == ["sub-1"])
    }

    /// Silent on every failure, deliberately: this runs because a screen
    /// appeared rather than because anybody asked, so an offline phone goes on
    /// showing *waiting for review* — which is what it showed before and is
    /// still the most accurate thing anybody can say.
    @Test("a failed check says nothing and writes nothing")
    func failuresAreSilent() async throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        hike.communityPhotoSubmissionID = "sub-1"
        let transport = StubCommunityTransport()
        transport.contributionResult = .failure(.unreachable)

        #expect(await !CommunityContributionCheck.refresh(hike, transport: transport))
        #expect(hike.communityPhotoContributionID == nil)
    }

    /// A `nil` is *no record yet* and not *declined*, so nothing is written
    /// and the hike stays exactly where it was. The state a contribution
    /// spends almost all of its life in.
    @Test("no published record yet writes nothing")
    func noAnswerYet() async throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        hike.communityPhotoSubmissionID = "sub-1"
        let transport = StubCommunityTransport()

        #expect(await !CommunityContributionCheck.refresh(hike, transport: transport))
        #expect(hike.communityPhotoContributionID == nil)
        #expect(
            CommunityContributionState(
                submissionID: hike.communityPhotoSubmissionID,
                contributionID: hike.communityPhotoContributionID
            ) == .awaitingReview
        )
    }

    /// The window a second send opens: an answer about the *previous*
    /// submission landing after the columns have moved on. Writing it back
    /// would report a set no reviewer has seen as live, and — because the
    /// check skips a hike that already has one — would stop the new one ever
    /// being asked about.
    @Test("an answer about a replaced submission is dropped")
    func aStaleAnswerIsDropped() async throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        hike.communityPhotoSubmissionID = "sub-1"
        let transport = StubCommunityTransport()
        transport.contributionResult = .success("contribution-for-sub-1")

        let gate = AsyncGate()
        transport.beforeContributionReturns = { await gate.wait() }

        let check = Task { await CommunityContributionCheck.refresh(hike, transport: transport) }
        await settleDelegateHop(until: "the check reaches the transport") {
            transport.recording.contributionChecks == ["sub-1"]
        }
        // The second send lands while the check is waiting, which is a tap on
        // another device as easily as a second tap here: both columns are
        // mirrored, in the shape ``CommunityPhotoPublisher/contribute`` writes
        // them — a new submission, and this device's memory of the old
        // publication cleared alongside it.
        hike.communityPhotoSubmissionID = "sub-2"
        hike.communityPhotoContributionID = nil
        await gate.open()
        let refreshed = await check.value

        #expect(!refreshed)
        #expect(hike.communityPhotoContributionID == nil)
    }
}
