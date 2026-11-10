//
//  CloudKitReviewQueuePagingTests.swift
//  OpenHikesTests
//
//  How much of the queue one look reads, once notices that are not work are
//  taken out of it.
//

import CloudKit
import Foundation
@testable import OpenHikes
import Testing

/// The queue shows at most fifty entries, oldest first. Notices are filtered
/// after the server has counted them — one whose submission is already
/// published, because the delete after a publication failed, is left out — so
/// a ceiling on *notices* let fifty leftovers fill the front of the queue and
/// hide the work behind them on every look, with no cursor kept to reach it.
/// The ceiling is on entries a reviewer can act on, and a page spent on
/// leftovers buys another, within a budget.
///
/// These run the real queue read, and the real publication where one is part
/// of the story, over ``ScriptedReviewDatabase``. No suite may reach the
/// public database.
@MainActor
@Suite("Review queue: paging past leftovers")
struct CloudKitReviewQueuePagingTests {
    private static func hikeIDs(_ range: ClosedRange<Int>) -> [String] {
        range.map { "hike-\($0)" }
    }

    /// Queued hikes, oldest first.
    private static func queued(_ ids: [String]) -> [CKRecord] {
        ids.flatMap(ReviewQueueFixture.hike)
    }

    /// Queued hikes that are already published, their notices left behind.
    private static func leftovers(_ ids: [String]) -> [CKRecord] {
        queued(ids) + ids.map(ReviewQueueFixture.listing(publishing:))
    }

    /// The pages of the notice query one look asked for, by how many rows each
    /// asked for.
    private static func noticePages(in database: ScriptedReviewDatabase) -> [Int] {
        database.requests.compactMap { request in
            guard case .query(CommunitySchema.noticeType, let resultsLimit) = request else { return nil }
            return resultsLimit
        }
    }

    /// The scene the issue describes, built through the real publication:
    /// fifty hikes published while every cleanup after them was refused, then
    /// one more submission.
    @Test("a first page of published hikes does not hide the submission behind it")
    func publishedPageDoesNotHideWork() async throws {
        let published = Self.hikeIDs(1...50)
        let database = ScriptedReviewDatabase(records: Self.queued(published))
        database.refuseDeletes(of: published.map(ReviewQueueFixture.noticeName), with: CKError(.networkFailure))
        for row in try await CloudKitCommunityTransport.reviewQueue(in: database).hikes {
            _ = try await CloudKitCommunityTransport.publish(ReviewQueueFixture.stamped(row), in: database)
        }
        #expect(database.recordNames(of: CommunitySchema.noticeType).count == 50, "every cleanup was refused")

        database.insert(ReviewQueueFixture.hike("hike-51"))
        let queue = try await CloudKitCommunityTransport.reviewQueue(in: database)

        #expect(queue.hikes.map(\.submissionID) == ["hike-51"])
    }

    @Test("a first page of published photographs does not hide the hike behind it")
    func publishedPhotosDoNotHideWork() async throws {
        let published = (1...50).map { "photos-\($0)" }
        let database = ScriptedReviewDatabase(
            records: published.flatMap { ReviewQueueFixture.photos($0) }
                + published.map(ReviewQueueFixture.contribution(publishing:))
                + ReviewQueueFixture.hike("hike-1")
        )

        let queue = try await CloudKitCommunityTransport.reviewQueue(in: database)

        #expect(queue.photographs.isEmpty)
        #expect(queue.hikes.map(\.submissionID) == ["hike-1"])
    }

    /// Each later page asks only for the slots still empty, so the ceiling
    /// holds and nothing newer can take an older entry's place.
    @Test("the ceiling is fifty entries to act on, the oldest fifty")
    func ceilingCountsWorkOldestFirst() async throws {
        let database = ScriptedReviewDatabase(
            records: Self.leftovers(Self.hikeIDs(1...10)) + Self.queued(Self.hikeIDs(11...70))
        )

        let queue = try await CloudKitCommunityTransport.reviewQueue(in: database)

        #expect(queue.hikes.map(\.submissionID) == Self.hikeIDs(11...60))
        #expect(Self.noticePages(in: database) == [50, 10])
    }

    /// The ordinary queue: nothing filtered out, so the first page is the
    /// answer however much is behind it, and nothing asks for a second.
    @Test("a queue with nothing to skip costs one page", arguments: [30, 50, 60])
    func nothingToSkipCostsOnePage(queued count: Int) async throws {
        let database = ScriptedReviewDatabase(records: Self.queued(Self.hikeIDs(1...count)))

        let queue = try await CloudKitCommunityTransport.reviewQueue(in: database)

        #expect(queue.hikes.map(\.submissionID) == Self.hikeIDs(1...min(count, 50)))
        #expect(Self.noticePages(in: database) == [50])
    }

    /// A queue of nothing but leftovers is pathological, and what bounds its
    /// cost is the page budget: past it the answer is whatever was found,
    /// which here is nothing.
    @Test("the page budget bounds a queue of nothing but leftovers")
    func budgetBoundsLeftovers() async throws {
        let pages = CloudKitCommunityTransport.queuePages
        let database = ScriptedReviewDatabase(
            records: Self.leftovers(Self.hikeIDs(1...(pages * 50))) + Self.queued(["hike-late"])
        )

        let queue = try await CloudKitCommunityTransport.reviewQueue(in: database)

        #expect(queue.isEmpty)
        #expect(Self.noticePages(in: database) == Array(repeating: 50, count: pages))
    }

    /// The first page settled that the account may read the queue, so a later
    /// one failing is not a refusal, and what was already found is real work.
    @Test("a later page that fails keeps what the earlier pages found")
    func laterFailureKeepsEarlierPages() async throws {
        let database = ScriptedReviewDatabase(
            records: Self.queued(Self.hikeIDs(1...5))
                + Self.leftovers(Self.hikeIDs(6...50))
                + Self.queued(Self.hikeIDs(51...60))
        )
        database.refuseNoticePage(1, with: CKError(.networkFailure))

        let queue = try await CloudKitCommunityTransport.reviewQueue(in: database)

        #expect(queue.hikes.map(\.submissionID) == Self.hikeIDs(1...5))
    }

    /// The first page is still the reviewer check: a refusal there is thrown,
    /// not turned into an empty queue. See ``CommunityReviewQueue/isReviewer``.
    @Test("a refused first page is still a refusal")
    func refusedFirstPageThrows() async throws {
        let database = ScriptedReviewDatabase(records: Self.queued(Self.hikeIDs(1...3)))
        database.refuseNoticePage(0, with: CKError(.permissionFailure))

        await #expect(throws: CommunityFailure.notPermitted) {
            try await CloudKitCommunityTransport.reviewQueue(in: database)
        }
    }

    /// Paging reads more of the queue and nothing else: every query is of the
    /// notices or of a published type, never of a submission type, whose
    /// missing index is what keeps pending uploads from being listed.
    @Test("paging queries only the notices and the published types")
    func pagingQueriesNoSubmissionType() async throws {
        let database = ScriptedReviewDatabase(
            records: Self.leftovers(Self.hikeIDs(1...50))
                + ReviewQueueFixture.photos("photos-1")
                + Self.queued(["hike-51"])
        )

        _ = try await CloudKitCommunityTransport.reviewQueue(in: database)

        let queried = Set(database.requests.compactMap { request -> String? in
            guard case .query(let recordType, _) = request else { return nil }
            return recordType
        })
        #expect(queried == [CommunitySchema.noticeType, CommunitySchema.listingType, CommunitySchema.contributionType])
    }
}

private extension CKError {
    /// `CKError` has no public initializer, and a real one needs the service —
    /// the same shape ``CommunityFailureMappingTests`` builds.
    init(_ code: Code) {
        self.init(_nsError: NSError(domain: CKErrorDomain, code: code.rawValue))
    }
}
