//
//  SeededCommunityReviewingTests.swift
//  OpenHikesTests
//
//  The reviewer's half of the seeded database: which scenario has a queue,
//  what is in it, and what a decision taken on one of its entries does.
//
//  Split from ``SeededCommunityTransportTests`` for length alone — the case
//  for asserting on this stand-in at all is made there. What is particular to
//  this half is that two of the scenarios it separates are otherwise
//  identical: ``SeededCommunityTransport/Scenario/seeded`` and
//  ``SeededCommunityTransport/Scenario/published`` differ in one answer, and
//  ``SeededCommunityTransport/Scenario/reviewing`` is the only one that has a
//  queue at all. Each is the sole route to a screen no other launch can reach,
//  so a scenario that stopped differing would take a screen out of the UI
//  suite's reach without taking a test with it.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import Testing

/// Short for ``SeededCommunityFixture``. Not `Fixture`, which this bundle
/// already uses for the shared route and container fixtures.
private typealias Seed = SeededCommunityFixture

@Suite("Seeded community reviewing")
struct SeededCommunityReviewingTests {
    // MARK: Publication, which is what promotes a hike

    /// The only route to the *published* state from automation, and the one
    /// thing separating two scenarios that are otherwise identical.
    @Test("only the published scenario says a submission was published")
    func publicationDependsOnTheScenario() async throws {
        let submissionID = "seeded-listing-ridge-submission"

        let published = try await Seed.transport(.published).publication(of: submissionID)
        #expect(published?.submissionID == submissionID)

        let awaitingReview = try await Seed.transport(.seeded).publication(of: submissionID)
        #expect(awaitingReview == nil)
        let inTheQueue = try await Seed.transport(.reviewing).publication(of: submissionID)
        #expect(inTheQueue == nil)
    }

    /// The id is the load-bearing part: a withdrawal request names that
    /// record, so a listing borrowed from another hike would make the request
    /// point at something else entirely.
    @Test("a published listing carries the id of the submission it is for")
    func publishedListingNamesItsSubmission() async throws {
        let first = try #require(
            try await Seed.transport(.published).publication(of: "submission-one")
        )
        let second = try #require(
            try await Seed.transport(.published).publication(of: "submission-two")
        )

        #expect(first.id != second.id)
        #expect(first.id.contains("submission-one"))
    }

    // MARK: Reviewing

    /// A refusal, not an empty list — the two are different answers, and an
    /// allowed empty queue would put *Take Down* on every published hike.
    @Test("a queue is refused outright to a scenario that is not reviewing")
    func queueIsRefusedOutsideTheRole() async {
        for scenario in [SeededCommunityTransport.Scenario.seeded, .published, .empty] {
            await #expect(throws: CommunityFailure.notPermitted) {
                _ = try await Seed.transport(scenario).reviewQueue()
            }
        }
    }

    /// Two entries, deliberately unalike: one a reviewer has to read and look
    /// at, one with nothing but a title, a credit and a line on the map.
    @Test("the reviewing scenario holds two unalike submissions")
    func queueHoldsTwoShapes() async throws {
        let queue = try await Seed.transport(.reviewing).reviewQueue().hikes
        #expect(queue.count == 2)

        let described = queue.filter { !$0.trackDescription.isEmpty }
        #expect(described.count == 1)
        #expect(described.first?.title == SeededCommunityTransport.queuedPhotographedTitle)

        // The count arrives with the photographs, from the screen that fetches
        // them — which is the production shape, and what makes a reviewer open
        // the preview to see one.
        #expect(queue.allSatisfy { $0.photoCount == 0 })

        // Queue titles share no word with the published three, so a scenario
        // asserting the review section is separate cannot be fooled by a match
        // across both lists.
        let published = Set(
            SeededCommunityTransport.seededListings
                .flatMap { $0.title.lowercased().split(separator: " ") }
        )
        for entry in queue {
            let words = Set(entry.title.lowercased().split(separator: " "))
            #expect(words.isDisjoint(with: published))
        }
    }

    @Test("a queued hike with photographs downloads them, and one without does not")
    func pendingDetailFollowsTheSubmission() async throws {
        let directory = try Seed.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }

        let transport = Seed.transport(.reviewing)
        let queue = try await transport.reviewQueue().hikes

        let photographed = try #require(
            queue.first { $0.title == SeededCommunityTransport.queuedPhotographedTitle }
        )
        let withPhotos = try await transport.detail(
            ofPending: photographed,
            downloadingInto: directory
        )
        #expect(withPhotos.photoFileURLs.count == SeededCommunityTransport.photographedCount)
        #expect(withPhotos.hasEveryPhoto)
        #expect(withPhotos.trackDescription?.isEmpty == false)

        let plain = try #require(
            queue.first { $0.title == SeededCommunityTransport.queuedTitle }
        )
        let withoutPhotos = try await transport.detail(
            ofPending: plain,
            downloadingInto: directory
        )
        #expect(withoutPhotos.photoFileURLs.isEmpty)
        // The hiker's own words, absent rather than synthesised from the title
        // — judging them is most of the job, and there are none here.
        #expect(withoutPhotos.trackDescription == nil)
    }

    /// The three decisions, and the rewrite that goes with one of them. None
    /// of them has a record to change here; what a scenario can see is that
    /// they succeed under a working database and refuse under a broken one.
    @Test("a reviewer's decisions succeed, and a broken database refuses them")
    func reviewerDecisions() async throws {
        let transport = Seed.transport(.reviewing)
        let queue = try await transport.reviewQueue().hikes
        let pending = try #require(queue.first)
        let staging = try Seed.scratch()
        defer { try? FileManager.default.removeItem(at: staging) }

        try await transport.keepOnlyPhotos([], of: pending, staging: staging)
        let listing = try await transport.publish(pending)
        #expect(listing.submissionID == pending.submissionID)
        try await transport.decline(pending)
        try await transport.takeDown(listing)

        let broken = Seed.transport(.failing)
        await #expect(throws: CommunityFailure.unreachable) {
            try await broken.keepOnlyPhotos([], of: pending, staging: staging)
        }
        await #expect(throws: CommunityFailure.unreachable) {
            _ = try await broken.publish(pending)
        }
        await #expect(throws: CommunityFailure.unreachable) {
            try await broken.decline(pending)
        }
        await #expect(throws: CommunityFailure.unreachable) {
            try await broken.takeDown(listing)
        }
        await #expect(throws: CommunityFailure.unreachable) {
            _ = try await broken.publication(of: pending.submissionID)
        }
    }
}
