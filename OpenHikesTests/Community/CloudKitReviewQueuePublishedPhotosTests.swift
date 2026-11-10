//
//  CloudKitReviewQueuePublishedPhotosTests.swift
//  OpenHikesTests
//
//  Contributed photographs whose publication landed and whose queue entry
//  did not go with it.
//

import CloudKit
import Foundation
@testable import OpenHikes
import Testing

/// Publishing contributed photographs is two requests: the published
/// contribution, then the delete of the notice that queued it. The second can
/// fail after the first has landed, and the publication is reported as the
/// success it was, because the photographs are live. What that leaves is a
/// notice for photographs that are already published — and the next look at
/// the queue used to offer them again. Publishing them twice puts a second set
/// on the hike; declining them deletes the submission the published set reads
/// its pictures from.
///
/// These run the real queue read and the real publication over
/// ``ScriptedReviewDatabase``, because what is under test is the order of
/// their requests. No suite may reach the public database.
@MainActor
@Suite("Review queue: published photographs")
struct CloudKitReviewQueuePublishedPhotosTests {
    /// Publishes the queued set for `photoSubmissionID` with its notice's
    /// delete refused, and returns what the publication answered.
    private static func publishLeavingTheNotice(
        _ photoSubmissionID: String,
        in database: ScriptedReviewDatabase
    ) async throws -> CommunityPhotoContribution {
        database.refuseDeletes(
            of: [ReviewQueueFixture.noticeName(for: photoSubmissionID)],
            with: CKError(.networkFailure)
        )
        let queue = try await CloudKitCommunityTransport.reviewQueue(in: database)
        let row = try #require(queue.photographs.first { $0.photoSubmissionID == photoSubmissionID })
        return try await CloudKitCommunityTransport.publishPhotos(ReviewQueueFixture.stamped(row), in: database)
    }

    @Test("photographs published while their notice could not be cleared are not offered again")
    func publishedPhotosLeaveTheQueue() async throws {
        let database = ScriptedReviewDatabase(records: ReviewQueueFixture.photos("photos-1"))

        let published = try await Self.publishLeavingTheNotice("photos-1", in: database)

        #expect(published.photoSubmissionID == "photos-1", "the publication is reported as the success it was")
        #expect(database.contains(ReviewQueueFixture.noticeName(for: "photos-1")), "the cleanup was refused")

        // The next look, and the one after it: nothing is offered, so nothing
        // can be published a second time or declined out from under the set.
        for _ in 1...2 {
            let refreshed = try await CloudKitCommunityTransport.reviewQueue(in: database)
            #expect(refreshed.photographs.isEmpty)
        }
        #expect(database.recordNames(of: CommunitySchema.contributionType).count == 1)
        #expect(database.contains("photos-1"), "the published set's photographs are still on their submission")
    }

    @Test("only the published set leaves the queue, and the one beside it stays")
    func unpublishedSetStays() async throws {
        let database = ScriptedReviewDatabase(
            records: ReviewQueueFixture.photos("photos-1") + ReviewQueueFixture.photos("photos-2")
        )

        _ = try await Self.publishLeavingTheNotice("photos-1", in: database)
        let refreshed = try await CloudKitCommunityTransport.reviewQueue(in: database)

        #expect(refreshed.photographs.map(\.photoSubmissionID) == ["photos-2"])
    }

    /// Asked of the published type through its queryable back-reference, never
    /// of a submission type: ``CommunitySchema/photoSubmissionType`` has no
    /// index, and that absence is what keeps pending uploads from being listed.
    @Test("the check asks the published contributions, never a submission type")
    func checkAsksThePublishedType() async throws {
        let database = ScriptedReviewDatabase(records: ReviewQueueFixture.photos("photos-1"))
        _ = try await Self.publishLeavingTheNotice("photos-1", in: database)
        database.forgetRequests()

        _ = try await CloudKitCommunityTransport.reviewQueue(in: database)

        let queried = database.requests.compactMap { request -> String? in
            guard case .query(let recordType, _) = request else { return nil }
            return recordType
        }
        #expect(queried == [CommunitySchema.noticeType, CommunitySchema.contributionType])
    }

    /// Best effort, as the hike half's check is: a check that fails shows a set
    /// that may be published already, which the review screen lets a reviewer
    /// see for themselves, rather than refusing to draw the queue at all.
    @Test("a check that fails offers the set rather than failing the queue")
    func failedCheckOffersTheSet() async throws {
        let database = ScriptedReviewDatabase(records: ReviewQueueFixture.photos("photos-1"))
        _ = try await Self.publishLeavingTheNotice("photos-1", in: database)
        database.refuseQueries(of: CommunitySchema.contributionType, with: CKError(.networkFailure))

        let refreshed = try await CloudKitCommunityTransport.reviewQueue(in: database)

        #expect(refreshed.photographs.map(\.photoSubmissionID) == ["photos-1"])
    }
}

private extension CKError {
    /// `CKError` has no public initializer, and a real one needs the service —
    /// the same shape ``CommunityFailureMappingTests`` builds.
    init(_ code: Code) {
        self.init(_nsError: NSError(domain: CKErrorDomain, code: code.rawValue))
    }
}
