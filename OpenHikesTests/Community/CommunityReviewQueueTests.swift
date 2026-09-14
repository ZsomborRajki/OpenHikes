//
//  CommunityReviewQueueTests.swift
//  OpenHikesTests
//

import Foundation
@testable import OpenHikes
import Testing

/// The reviewer's queue: when it asks, what it does with an answer, and what
/// it does with a failure.
///
/// Its own suite because what is being pinned here is not a list — it is the
/// two decisions that make the list safe to put in every hiker's app. The
/// queue is asked for by *everybody*, and the server is what answers
/// differently; so the things worth asserting are that an ordinary launch
/// spends one request on it and draws nothing, and that a failure draws
/// nothing either. A row would be a feature almost nobody has, reported as an
/// error almost nobody could act on.
@MainActor
@Suite("Community review queue")
struct CommunityReviewQueueTests {
    /// Waits on the effect rather than a duration, the way the browser suites
    /// do.
    private func settle(_ queue: CommunityReviewQueue) async {
        while queue.isLoading {
            await Task.yield()
        }
    }

    @Test("selecting the tab asks once and keeps what came back")
    func selectingTheTabAsksOnce() async {
        let transport = StubCommunityTransport()
        transport.pendingResult = .success([.stub(), .stub(id: "notice-2")])
        let queue = CommunityReviewQueue(transport: transport)

        queue.startBrowsing()
        await settle(queue)

        #expect(queue.pending.count == 2)
        #expect(transport.recording.queueRequests == 1)
    }

    /// The point of the once-a-launch rule: two segments a tap apart, and
    /// almost every hiker's answer is the same empty list every time.
    @Test("leaving the tab and coming back does not ask again")
    func returningToTheTabDoesNotAskAgain() async {
        let transport = StubCommunityTransport()
        transport.pendingResult = .success([.stub()])
        let queue = CommunityReviewQueue(transport: transport)

        queue.startBrowsing()
        await settle(queue)
        queue.stopBrowsing()
        queue.startBrowsing()
        await settle(queue)

        #expect(transport.recording.queueRequests == 1, "one launch, one question")
    }

    /// The section came back empty after a trip to *My Hikes* and stayed empty
    /// until the app was relaunched, and this is the pair of rules that did
    /// it: leaving emptied the list, and coming back declined to ask again
    /// because the launch had already had its one question. Each was
    /// defensible alone. Together they meant a reviewer got one look.
    ///
    /// The rows are what gave way. A queue is not an answer about an area of
    /// the map — nothing that happens between the two segments can make it
    /// wrong — so there is nothing to protect by throwing it away, and a whole
    /// launch's worth of usefulness to lose.
    @Test("leaving the tab and coming back still shows the queue")
    func leavingAndReturningKeepsTheRows() async {
        let transport = StubCommunityTransport()
        transport.pendingResult = .success([.stub(), .stub(id: "notice-2")])
        let queue = CommunityReviewQueue(transport: transport)

        queue.startBrowsing()
        await settle(queue)
        #expect(queue.pending.count == 2)

        queue.stopBrowsing()
        queue.startBrowsing()
        await settle(queue)

        #expect(queue.pending.count == 2, "the rows are still there")
        #expect(queue.isReviewer)
        #expect(transport.recording.queueRequests == 1, "and cost nothing to get back")
    }

    /// The same disappearance in a narrower window: leave during the one
    /// request of the launch and it is cancelled, so the launch has asked and
    /// been told nothing. Coming back has to ask, or the queue is empty for
    /// the rest of the launch for a reason nobody can see.
    @Test("a request abandoned on the way out is asked again on the way back")
    func anAbandonedRequestIsAskedAgain() async {
        let transport = StubCommunityTransport()
        transport.pendingResult = .success([.stub()])
        let gate = AsyncGate()
        transport.beforeQueueReturns = { await gate.wait() }
        let queue = CommunityReviewQueue(transport: transport)

        queue.startBrowsing()
        queue.stopBrowsing()
        // Open before the second selection, so the replacement request is not
        // held behind the abandoned one.
        await gate.open()
        queue.startBrowsing()
        await settle(queue)

        #expect(transport.recording.queueRequests == 2)
        #expect(queue.pending.count == 1)
    }

    /// What every hiker who is not a reviewer gets: the server refuses the
    /// read, and nothing is drawn or said.
    @Test("a refused queue leaves nothing to draw and nobody a reviewer")
    func aRefusedQueueDrawsNothing() async {
        let transport = StubCommunityTransport()
        transport.pendingResult = .failure(.notPermitted)
        let queue = CommunityReviewQueue(transport: transport)

        queue.startBrowsing()
        await settle(queue)

        #expect(queue.pending.isEmpty)
        #expect(!queue.isReviewer)
        #expect(transport.recording.queueRequests == 1)
    }

    /// The case an empty ``pending`` cannot express on its own, and the reason
    /// ``isReviewer`` is a separate answer: somebody who has cleared their
    /// queue is still the person who may take a published hike down.
    @Test("an empty queue that was allowed still means reviewer")
    func anAllowedEmptyQueueStillMeansReviewer() async {
        let transport = StubCommunityTransport()
        transport.pendingResult = .success([])
        let queue = CommunityReviewQueue(transport: transport)

        queue.startBrowsing()
        await settle(queue)

        #expect(queue.pending.isEmpty)
        #expect(queue.isReviewer, "the read succeeded, which is the whole signal")
    }

    /// A reviewer in a valley is still a reviewer. Dropping the answer on a
    /// network failure would take the takedown action away for the rest of the
    /// launch, for a reason that has nothing to do with permission.
    @Test("a network failure does not revoke the reviewer answer")
    func aNetworkFailureDoesNotRevokeReviewer() async {
        let transport = StubCommunityTransport()
        transport.pendingResult = .success([.stub()])
        let queue = CommunityReviewQueue(transport: transport)
        queue.startBrowsing()
        await settle(queue)
        #expect(queue.isReviewer)

        transport.pendingResult = .failure(.unreachable)
        queue.refresh()
        await settle(queue)

        #expect(queue.isReviewer, "unreachable is not a refusal")
    }

    /// The one list in this feature that fails silently, and deliberately.
    ///
    /// A phone in a valley belonging to somebody who has never heard of review
    /// must not get a *couldn't load the review queue* row. There is no state
    /// to assert *except* the absence of one, which is exactly why this is
    /// worth a test: silence here reads as an oversight to anybody who has not
    /// read ``CommunityReviewQueue``'s header.
    @Test("a failed load says nothing and leaves the list empty")
    func aFailedLoadSaysNothing() async {
        let transport = StubCommunityTransport()
        transport.pendingResult = .failure(.unreachable)
        let queue = CommunityReviewQueue(transport: transport)

        queue.startBrowsing()
        await settle(queue)

        #expect(queue.pending.isEmpty)
        #expect(!queue.isLoading)
    }

    /// The one thing that asks again, whatever has been asked before — without
    /// it a reviewer who published something would be looking at a launch-old
    /// list until they quit the app.
    @Test("refreshing asks again")
    func refreshingAsksAgain() async {
        let transport = StubCommunityTransport()
        transport.pendingResult = .success([.stub()])
        let queue = CommunityReviewQueue(transport: transport)

        queue.startBrowsing()
        await settle(queue)
        queue.refresh()
        await settle(queue)

        #expect(transport.recording.queueRequests == 2)
    }

    /// A launch with no transport is one that must not reach CloudKit at all —
    /// a hosted suite, or UI automation that named no scenario. It must not
    /// reach it for this either.
    @Test("no transport asks nothing")
    func noTransportAsksNothing() async {
        let queue = CommunityReviewQueue(transport: nil)

        queue.startBrowsing()
        await settle(queue)

        #expect(queue.pending.isEmpty)
        #expect(queue.issuedRequests == 0)
    }

    /// The row goes at once rather than after a round trip, because the
    /// decision has already landed: both actions delete the notice. A reviewer
    /// left looking at a hike they have just dealt with is the state that
    /// invites dealing with it twice.
    @Test("a decided submission is forgotten without asking again")
    func decidedSubmissionsAreForgotten() async {
        let transport = StubCommunityTransport()
        let decided = CommunityPendingSubmission.stub(id: "notice-1")
        let other = CommunityPendingSubmission.stub(id: "notice-2")
        transport.pendingResult = .success([decided, other])
        let queue = CommunityReviewQueue(transport: transport)

        queue.startBrowsing()
        await settle(queue)
        queue.forget(decided)

        #expect(queue.pending.map(\.id) == ["notice-2"])
        #expect(transport.recording.queueRequests == 1, "no round trip to drop a row")
    }

    /// The other half of dropping the row: the launch's one question has been
    /// spent. A reviewer who publishes something and comes back to the tab is
    /// the one person in the app whose answer is known to be out of date, and
    /// without this they would be looking at the queue as it stood at launch
    /// until they quit — never seeing anything that arrived while they worked.
    @Test("acting spends the launch's question, so the next selection asks again")
    func actingMakesTheNextSelectionAskAgain() async {
        let transport = StubCommunityTransport()
        let decided = CommunityPendingSubmission.stub(id: "notice-1")
        transport.pendingResult = .success([decided, .stub(id: "notice-2")])
        let queue = CommunityReviewQueue(transport: transport)

        queue.startBrowsing()
        await settle(queue)
        queue.forget(decided)
        #expect(transport.recording.queueRequests == 1, "not on the way back to the list")

        queue.stopBrowsing()
        queue.startBrowsing()
        await settle(queue)

        #expect(transport.recording.queueRequests == 2)
        #expect(queue.pending.map(\.id) == ["notice-1", "notice-2"], "the server's answer, not ours")
    }

    /// The guard that keeps two requests from overlapping has to survive a
    /// cancelled one landing late. Without a generation to check, the
    /// superseded task clears ``isLoading`` for the request that replaced it,
    /// and the next caller gets to start a third.
    @Test("a superseded request does not clear the flag for the one that replaced it")
    func aSupersededRequestLeavesTheFlagAlone() async {
        let transport = StubCommunityTransport()
        transport.pendingResult = .success([.stub()])
        let queue = CommunityReviewQueue(transport: transport)
        let gate = AsyncGate()
        transport.beforeQueueReturns = { await gate.wait() }

        queue.startBrowsing()
        // Cancel the first without waiting on it, then start a second that is
        // still in flight when the first comes back.
        queue.stopBrowsing()
        queue.refresh()
        await gate.open()
        await settle(queue)

        #expect(transport.recording.queueRequests == 2)
        #expect(queue.pending.count == 1, "the second answer stands")
        #expect(!queue.isLoading)
    }
}

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
        #expect(listing.authorID == "author-7")
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
