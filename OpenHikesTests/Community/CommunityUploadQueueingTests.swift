//
//  CommunityUploadQueueingTests.swift
//  OpenHikesTests
//
//  What a hike remembers when its upload landed and its review notice did not,
//  and what finishing that upload does and does not send.
//
//  ``CloudKitCommunityTransportQueueingTests`` pins the two saves themselves.
//  This suite is the half above them: the stub refuses the notice the way the
//  transport would, and the questions are about the hike — which columns are
//  written, which survive a relaunch, and what the second attempt is allowed to
//  touch. The line it is built around is that **an upload which reached the
//  public database is never sent twice**, so every finish asserts what the
//  transport was *not* asked to do as well as what it was.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import SwiftData
import Testing

@MainActor
@Suite("Community upload queueing")
struct CommunityUploadQueueingTests {
    // MARK: A hike whose notice failed

    /// The reported bug, from the hike's side. The upload is in the public
    /// database, so the hike has to keep its name — in the column everything
    /// else already reads, and in the marker that says the notice is owed.
    @Test("a hike whose notice fails keeps the submission that landed")
    func routeNoticeFailureKeepsTheSubmission() async throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        let transport = stubFailingTheNotice(submissionID: "submission-7")

        let outcome = await CommunityPublisher.share(hike, authorName: "Anna", transport: transport)

        #expect(outcome == .uploadedNotQueued(.unreachable))
        #expect(hike.communitySubmissionID == "submission-7")
        #expect(hike.unqueuedSubmissionID == "submission-7")
        #expect(hike.pendingCommunityQueueing == "submission-7")
        let recording = transport.recording
        #expect(recording.submissions.count == 1)
        #expect(recording.queueAttempts == ["submission-7"])
    }

    /// The upload carried the photographs, so they are sent, whatever happened
    /// to the notice. Leaving them unmarked would offer the same pictures again
    /// the next time the hiker contributed, and a second copy in a gallery is
    /// for good.
    @Test("the photographs that went up are marked sent even though the notice failed")
    func routeNoticeFailureStillMarksThePhotosSent() async throws {
        let context = try Fixture.modelContext()
        let sandbox = PhotoStoreSandbox()
        let hike = Fixture.hike(in: context)
        await addStoredPhotos(2, to: hike, in: sandbox)
        let transport = stubFailingTheNotice(submissionID: "submission-7")

        let outcome = await CommunityPublisher.share(
            hike,
            authorName: "Anna",
            transport: transport,
            store: sandbox.store
        )

        #expect(outcome == .uploadedNotQueued(.unreachable))
        #expect(hike.photos.count == 2)
        #expect(hike.photos.allSatisfy { $0.sentToCommunityAt != nil })
    }

    /// Nothing about the contribution's marker may leak into the hike's, or
    /// the share button of a trail that is both would offer to finish an
    /// upload of the wrong kind.
    @Test("a contribution whose notice fails is remembered apart from the hike's own upload")
    func photoNoticeFailureKeepsTheSubmission() async throws {
        let context = try Fixture.modelContext()
        let sandbox = PhotoStoreSandbox()
        let hike = Fixture.hike(in: context)
        await addStoredPhotos(2, to: hike, in: sandbox)
        let transport = stubFailingTheNotice(submissionID: "photo-submission-7")

        let outcome = await CommunityPhotoPublisher.contribute(
            hike,
            to: Self.target,
            authorName: "Bern",
            transport: transport,
            store: sandbox.store
        )

        #expect(outcome == .uploadedNotQueued(.unreachable))
        #expect(hike.communityPhotoSubmissionID == "photo-submission-7")
        #expect(hike.unqueuedPhotoSubmissionID == "photo-submission-7")
        #expect(hike.pendingCommunityPhotoQueueing == "photo-submission-7")
        #expect(hike.communitySubmissionID == nil)
        #expect(hike.unqueuedSubmissionID == nil)
        #expect(hike.pendingCommunityQueueing == nil)
        let recording = transport.recording
        #expect(recording.photoDrafts.count == 1)
        #expect(recording.photoQueueAttempts == ["photo-submission-7"])
        #expect(hike.photos.allSatisfy { $0.sentToCommunityAt != nil })
    }

    // MARK: Finishing a hike

    /// The point of the whole change. The notice goes, the route does not.
    @Test("finishing a hike queues the upload that is already there")
    func finishingARouteQueuesTheSameSubmission() async throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        let transport = stubFailingTheNotice(submissionID: "submission-7")
        _ = await CommunityPublisher.share(hike, authorName: "Anna", transport: transport)

        let outcome = await CommunityPublisher.finishQueueing(hike, transport: transport)

        #expect(outcome == .submitted)
        #expect(hike.pendingCommunityQueueing == nil)
        #expect(hike.unqueuedSubmissionID == nil)
        // Still the hike's submission: finishing it must not make it look
        // unshared, or the share form would offer to send it again.
        #expect(hike.communitySubmissionID == "submission-7")
        let recording = transport.recording
        #expect(recording.submissions.count == 1)
        #expect(recording.queueAttempts == ["submission-7", "submission-7"])
    }

    /// A refused retry is the ordinary case on a phone with one bar, and it
    /// must leave everything as it was: the marker kept, and the next try as
    /// good as this one.
    @Test("a retry that fails leaves the hike exactly as unfinished as before")
    func failedFinishKeepsTheMarker() async throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        let transport = stubFailingTheNotice(
            submissionID: "submission-7",
            script: [.unreachable, .unreachable]
        )
        _ = await CommunityPublisher.share(hike, authorName: "Anna", transport: transport)

        let refused = await CommunityPublisher.finishQueueing(hike, transport: transport)

        #expect(refused == .uploadedNotQueued(.unreachable))
        #expect(hike.pendingCommunityQueueing == "submission-7")
        #expect(hike.communitySubmissionID == "submission-7")

        let accepted = await CommunityPublisher.finishQueueing(hike, transport: transport)

        #expect(accepted == .submitted)
        #expect(hike.pendingCommunityQueueing == nil)
        let recording = transport.recording
        #expect(recording.submissions.count == 1)
        #expect(recording.queueAttempts == ["submission-7", "submission-7", "submission-7"])
    }

    /// The marker is a column in the device-local store, which is what makes
    /// "close the app and come back" survivable. A fresh context over the same
    /// stores stands in for a relaunch: nothing that was only in memory is
    /// still there.
    @Test("an unfinished upload is still finishable after a relaunch")
    func finishingSurvivesARelaunch() async throws {
        let container = try Fixture.modelContainer()
        let id: UUID
        do {
            let context = ModelContext(container)
            let hike = Fixture.hike(in: context)
            let transport = stubFailingTheNotice(submissionID: "submission-7")
            let outcome = await CommunityPublisher.share(hike, authorName: "Anna", transport: transport)
            #expect(outcome == .uploadedNotQueued(.unreachable))
            id = hike.id
        }

        let context = ModelContext(container)
        let hike = try #require(
            try context.fetch(FetchDescriptor<Hike>(predicate: #Predicate { $0.id == id })).first
        )
        #expect(hike.pendingCommunityQueueing == "submission-7")

        let transport = StubCommunityTransport()
        let outcome = await CommunityPublisher.finishQueueing(hike, transport: transport)

        #expect(outcome == .submitted)
        #expect(hike.pendingCommunityQueueing == nil)
        let recording = transport.recording
        #expect(recording.submissions.isEmpty)
        #expect(recording.queueAttempts == ["submission-7"])
    }

    /// The mirrored column is what other devices and the share form read, and
    /// it can be nil under a marker that survived: the two live in different
    /// stores, and one commit can land without the other. The marker alone is
    /// enough to finish from, and finishing puts the column back so the hike
    /// reads *waiting for review* rather than unshared.
    @Test("a marker with no mirrored column is enough to finish from, and restores the column")
    func markerAloneIsEnough() async throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        hike.unqueuedSubmissionID = "submission-7"
        #expect(hike.communitySubmissionID == nil)
        #expect(hike.pendingCommunityQueueing == "submission-7")
        let transport = StubCommunityTransport()

        let outcome = await CommunityPublisher.finishQueueing(hike, transport: transport)

        #expect(outcome == .submitted)
        #expect(hike.communitySubmissionID == "submission-7")
        #expect(hike.pendingCommunityQueueing == nil)
        #expect(transport.recording.submissions.isEmpty)
    }

    // MARK: A marker that has gone stale

    /// A listing means a reviewer already saw it, so no marker can still be
    /// owed anything. This is the state another device leaves behind when it
    /// finished the upload first and the mirrored columns arrived here.
    @Test("a marker is stale once the listing exists")
    func listingMakesTheMarkerStale() async throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        hike.communitySubmissionID = "submission-7"
        hike.communityListingID = "listing-7"
        hike.unqueuedSubmissionID = "submission-7"
        let transport = StubCommunityTransport()

        #expect(hike.pendingCommunityQueueing == nil)
        let outcome = await CommunityPublisher.finishQueueing(hike, transport: transport)

        #expect(outcome == .submitted)
        let recording = transport.recording
        #expect(recording.queueAttempts.isEmpty)
        #expect(recording.publicationChecks.isEmpty)
    }

    /// A marker about a submission the hike has since replaced is about
    /// something that is no longer the hike's. Repairing it would queue a
    /// stranger's upload.
    @Test("a marker is stale once a different submission has replaced it")
    func replacedSubmissionMakesTheMarkerStale() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        hike.communitySubmissionID = "submission-8"
        hike.unqueuedSubmissionID = "submission-7"

        #expect(hike.pendingCommunityQueueing == nil)
        #expect(CommunityUploadKind.unfinished(of: hike) == nil)
    }

    /// The second attempt asks whether it is needed before it makes itself
    /// needed. A reviewer who already published the hike has made it live, and
    /// a notice written now would be a second entry in a queue for something
    /// nobody has to review.
    @Test("a hike that is already live is not queued again")
    func liveHikeIsNotQueuedAgain() async throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        let transport = stubFailingTheNotice(submissionID: "submission-7")
        _ = await CommunityPublisher.share(hike, authorName: "Anna", transport: transport)
        transport.publicationResult = .success(listing(id: "listing-7", submissionID: "submission-7"))

        let outcome = await CommunityPublisher.finishQueueing(hike, transport: transport)

        #expect(outcome == .submitted)
        #expect(hike.communityListingID == "listing-7")
        #expect(hike.pendingCommunityQueueing == nil)
        #expect(transport.recording.queueAttempts == ["submission-7"])
    }

    /// The submission is gone — declined, or deleted by a reviewer in the
    /// meantime — so there is nothing to queue and nothing to wait for. The
    /// hike goes back to being unshared, which is the one state from which it
    /// can be sent again.
    @Test("a submission that no longer exists releases the hike")
    func vanishedSubmissionReleasesTheHike() async throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        let transport = stubFailingTheNotice(
            submissionID: "submission-7",
            script: [.unreachable, .noLongerAvailable]
        )
        _ = await CommunityPublisher.share(hike, authorName: "Anna", transport: transport)

        let outcome = await CommunityPublisher.finishQueueing(hike, transport: transport)

        #expect(outcome == .refused(.noLongerAvailable))
        #expect(hike.communitySubmissionID == nil)
        #expect(hike.unqueuedSubmissionID == nil)
        #expect(hike.pendingCommunityQueueing == nil)
    }

    // MARK: Finishing a contribution

    @Test("finishing a contribution queues the upload that is already there")
    func finishingAContributionQueuesTheSameSubmission() async throws {
        let context = try Fixture.modelContext()
        let sandbox = PhotoStoreSandbox()
        let hike = Fixture.hike(in: context)
        await addStoredPhotos(2, to: hike, in: sandbox)
        let transport = stubFailingTheNotice(submissionID: "photo-submission-7")
        _ = await CommunityPhotoPublisher.contribute(
            hike,
            to: Self.target,
            authorName: "Bern",
            transport: transport,
            store: sandbox.store
        )

        let outcome = await CommunityPhotoPublisher.finishQueueing(hike, transport: transport)

        #expect(outcome == .submitted)
        #expect(hike.pendingCommunityPhotoQueueing == nil)
        #expect(hike.unqueuedPhotoSubmissionID == nil)
        #expect(hike.communityPhotoSubmissionID == "photo-submission-7")
        let recording = transport.recording
        #expect(recording.photoDrafts.count == 1)
        #expect(recording.photoQueueAttempts == ["photo-submission-7", "photo-submission-7"])
    }

    /// Unlike a hike, a contribution's absence from the queue does not heal
    /// itself — nothing lists the published sets the way the hike queue does —
    /// so this is the check that stands between a retry and a contribution a
    /// reviewer already published appearing in the queue a second time.
    @Test("a contribution that is already published is not queued again")
    func publishedContributionIsNotQueuedAgain() async throws {
        let context = try Fixture.modelContext()
        let sandbox = PhotoStoreSandbox()
        let hike = Fixture.hike(in: context)
        await addStoredPhotos(2, to: hike, in: sandbox)
        let transport = stubFailingTheNotice(submissionID: "photo-submission-7")
        _ = await CommunityPhotoPublisher.contribute(
            hike,
            to: Self.target,
            authorName: "Bern",
            transport: transport,
            store: sandbox.store
        )
        transport.contributionResult = .success("contribution-9")

        let outcome = await CommunityPhotoPublisher.finishQueueing(hike, transport: transport)

        #expect(outcome == .submitted)
        #expect(hike.communityPhotoContributionID == "contribution-9")
        #expect(hike.pendingCommunityPhotoQueueing == nil)
        #expect(transport.recording.photoQueueAttempts == ["photo-submission-7"])
    }

    @Test("a contribution that no longer exists releases the hike")
    func vanishedContributionReleasesTheHike() async throws {
        let context = try Fixture.modelContext()
        let sandbox = PhotoStoreSandbox()
        let hike = Fixture.hike(in: context)
        await addStoredPhotos(2, to: hike, in: sandbox)
        let transport = stubFailingTheNotice(
            submissionID: "photo-submission-7",
            script: [.unreachable, .noLongerAvailable]
        )
        _ = await CommunityPhotoPublisher.contribute(
            hike,
            to: Self.target,
            authorName: "Bern",
            transport: transport,
            store: sandbox.store
        )

        let outcome = await CommunityPhotoPublisher.finishQueueing(hike, transport: transport)

        #expect(outcome == .refused(.noLongerAvailable))
        #expect(hike.communityPhotoSubmissionID == nil)
        #expect(hike.unqueuedPhotoSubmissionID == nil)
        #expect(hike.pendingCommunityPhotoQueueing == nil)
    }

    // MARK: Which kind is unfinished

    /// The share button and the share sheet both ask this, and a hike can owe
    /// both at once — a published trail whose author kept adding pictures is
    /// the ordinary case for having both pairs of columns set. The route is
    /// finished first, because a contribution is about a listing that the
    /// route's own review is what creates.
    @Test("the route is finished before the photographs when both are owed")
    func routeIsFinishedFirst() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        #expect(CommunityUploadKind.unfinished(of: hike) == nil)

        hike.unqueuedPhotoSubmissionID = "photo-submission-7"
        #expect(CommunityUploadKind.unfinished(of: hike) == .photos)

        hike.unqueuedSubmissionID = "submission-7"
        #expect(CommunityUploadKind.unfinished(of: hike) == .route)
    }

    // MARK: Withdrawing

    /// Asking for a removal and then forgetting the publication is how a hiker
    /// starts over, and the marker is part of what is being started over from.
    /// Left behind, it would keep a share button offering to finish an upload
    /// of a submission this hike no longer has.
    @Test("forgetting a publication forgets what was owed for it")
    func forgettingThePublicationClearsTheMarker() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        hike.communitySubmissionID = "submission-7"
        hike.communityListingID = "listing-7"
        hike.unqueuedSubmissionID = "submission-7"

        let forgotten = CommunityPublicationCheck.forgetPublication(hike)

        #expect(forgotten)
        #expect(hike.communitySubmissionID == nil)
        #expect(hike.communityListingID == nil)
        #expect(hike.unqueuedSubmissionID == nil)
    }

    /// A refused reset promises the hike is exactly as it was, and the marker
    /// is cleared beside the columns before the save is tried — so it has to
    /// come back with them, or the next unrelated save makes half the reset
    /// durable.
    @Test("a refused reset puts the marker back with the columns")
    func refusedForgetKeepsTheMarker() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        hike.communitySubmissionID = "submission-7"
        hike.communityListingID = "listing-7"
        hike.unqueuedSubmissionID = "submission-7"

        let forgotten = CommunityPublicationCheck.forgetPublication(
            hike,
            save: { _ in throw CocoaError(.fileWriteNoPermission) }
        )

        #expect(!forgotten)
        #expect(hike.communitySubmissionID == "submission-7")
        #expect(hike.unqueuedSubmissionID == "submission-7")
    }
}
