//
//  CommunityPhotoTakedownTests.swift
//  OpenHikesTests
//
//  What a reviewer's takedown of contributed photographs does when one of its
//  two deletes does not go through.
//
//  The takedown is two deletes in a fixed order — the published
//  `CommunityPhotoContribution`, then the `CommunityPhotoSubmission` behind it
//  — and CloudKit has no way to make them one. So the ways it can end are the
//  ways the pair can stop part way, and each has to be told apart: a failure
//  before anything was removed, a failure after the photographs were already
//  off the hike, and a retry that meets a published record which is no longer
//  there. They are driven through
//  ``CloudKitCommunityTransport/takeDownPhotos(_:deleting:)``, which takes the
//  delete as a closure for exactly this reason: the real one is the public
//  database, and a suite must never reach it.
//

import CloudKit
import Foundation
@testable import OpenHikes
import Testing

@Suite("Community photo takedown")
struct CommunityPhotoTakedownTests {
    /// The two records behind one published set of photographs.
    private static let photos = CommunityPhotoContribution(
        id: "contribution-1",
        photoSubmissionID: "submission-1",
        authorName: "Aino",
        authorID: "author-1",
        publishedAt: Date(timeIntervalSince1970: 0),
        photoPins: [],
        photoFileURLs: []
    )

    /// What the transport answered, and which records it was asked to delete,
    /// in the order it asked.
    private typealias Run = (answer: Result<CommunityPhotoTakedownOutcome, CommunityFailure>, deleted: [String])

    /// Takes ``photos`` down against deletes that succeed unless told
    /// otherwise.
    ///
    /// - Parameters:
    ///   - contribution: What deleting the published record raises, if
    ///     anything.
    ///   - submission: What deleting the submission raises, if anything.
    private static func takeDown(
        contribution: CKError? = nil,
        submission: CKError? = nil
    ) async throws -> Run {
        let refusals = [photos.id: contribution, photos.photoSubmissionID: submission].compactMapValues { $0 }
        var deleted: [String] = []
        do {
            let outcome = try await CloudKitCommunityTransport.takeDownPhotos(photos, deleting: { id in
                deleted.append(id.recordName)
                if let refusal = refusals[id.recordName] { throw refusal }
            })
            return (.success(outcome), deleted)
        } catch let failure as CommunityFailure {
            return (.failure(failure), deleted)
        }
    }

    /// Both records go, and in the order the safety argument needs: the
    /// published one first, so a failure between the two leaves a submission
    /// nobody can reach rather than photographs on a hike pointing at nothing.
    @Test("both records are deleted, the published one first")
    func deletesTheListingThenTheSubmission() async throws {
        let run = try await Self.takeDown()

        #expect(run.answer == .success(.complete))
        #expect(run.deleted == [Self.photos.id, Self.photos.photoSubmissionID])
    }

    /// Nothing has been removed, so this is the whole takedown failing: a
    /// throw, and a screen that changes nothing about what it draws. The
    /// submission is not touched either — deleting the record behind
    /// photographs that are still on the hike is the half-state the order
    /// exists to prevent.
    @Test(
        "a failure before the first delete fails the whole takedown",
        arguments: [
            (CKError.Code.networkFailure, CommunityFailure.unreachable),
            (.notAuthenticated, .notSignedIn),
            (.permissionFailure, .notPermitted),
        ]
    )
    func failureBeforeAnythingIsRemoved(code: CKError.Code, expected: CommunityFailure) async throws {
        let run = try await Self.takeDown(contribution: CKError(code))

        #expect(run.answer == .failure(expected))
        #expect(run.deleted == [Self.photos.id], "the submission is left alone")
    }

    /// The published record is gone, so the photographs are off the hike for
    /// everybody. A throw here would say they are not, and the gallery would
    /// go on drawing pictures the next open of the trail will not return.
    @Test(
        "a failure after the photographs are unlisted says so instead of throwing",
        arguments: [
            (CKError.Code.networkFailure, CommunityFailure.unreachable),
            (.permissionFailure, .notPermitted),
        ]
    )
    func failureAfterUnlisting(code: CKError.Code, expected: CommunityFailure) async throws {
        let run = try await Self.takeDown(submission: CKError(code))

        #expect(run.answer == .success(.unlisted(cleanupFailure: expected)))
        #expect(run.deleted == [Self.photos.id, Self.photos.photoSubmissionID])
    }

    /// What a retry meets once the first attempt got as far as unlisting: the
    /// published record is not there. That used to end the retry before the
    /// submission was reached, so the cleanup could never be finished.
    @Test("a retry that finds the published record gone still deletes the submission")
    func retryFinishesTheCleanup() async throws {
        let run = try await Self.takeDown(contribution: CKError(.unknownItem))

        #expect(run.answer == .success(.complete))
        #expect(run.deleted == [Self.photos.id, Self.photos.photoSubmissionID])
    }

    /// A retry is allowed to fail on the same thing again, and says the same
    /// true thing when it does: the photographs are off the hike.
    @Test("a retry whose cleanup fails again is still an unlisting")
    func retryThatFailsAgain() async throws {
        let run = try await Self.takeDown(contribution: CKError(.unknownItem), submission: CKError(.networkFailure))

        #expect(run.answer == .success(.unlisted(cleanupFailure: .unreachable)))
        #expect(run.deleted == [Self.photos.id, Self.photos.photoSubmissionID])
    }

    /// Two reviewers on one set, or the same takedown run twice: the records
    /// are already where the takedown was headed, which is done and not a
    /// failure — whichever of the two was removed first.
    @Test("records that are already gone are a finished takedown")
    func alreadyGoneIsDone() async throws {
        let submissionOnly = try await Self.takeDown(submission: CKError(.unknownItem))
        let both = try await Self.takeDown(contribution: CKError(.unknownItem), submission: CKError(.unknownItem))

        #expect(submissionOnly.answer == .success(.complete))
        #expect(both.answer == .success(.complete))
        #expect(both.deleted == [Self.photos.id, Self.photos.photoSubmissionID])
    }

    /// CloudKit may spell a missing record as the error itself or as a partial
    /// failure that holds one. Which a single-record delete raises has not
    /// been observed, so both have to read as gone.
    @Test("a partial failure made only of missing records is read as already gone")
    func partialFailureOfMissingRecords() async throws {
        let run = try await Self.takeDown(contribution: CKError(.partialFailure, partial: [CKError(.unknownItem)]))

        #expect(run.answer == .success(.complete))
        #expect(run.deleted == [Self.photos.id, Self.photos.photoSubmissionID])
    }

    /// The other direction, so the tolerance cannot be written as "a partial
    /// failure is always fine": one real reason in it, or none at all, is a
    /// failure and stops before the submission.
    @Test(
        "a partial failure with anything else in it is a real failure",
        arguments: [
            [CKError.Code.unknownItem, .networkFailure],
            [.networkFailure],
            [],
        ]
    )
    func partialFailureWithAnythingElse(inside codes: [CKError.Code]) async throws {
        let run = try await Self.takeDown(
            contribution: CKError(.partialFailure, partial: codes.map { CKError($0) })
        )

        guard case .failure(.unavailable) = run.answer else {
            Issue.record("A partial failure that is not only missing records should not be read as already gone.")
            return
        }
        #expect(run.deleted == [Self.photos.id], "the submission is left alone")
    }
}

private extension CKError {
    /// `CKError` has no public initializer, and a real one needs the service —
    /// the same shape ``CommunityFailureMappingTests`` builds.
    init(_ code: Code) {
        self.init(_nsError: NSError(domain: CKErrorDomain, code: code.rawValue))
    }

    /// A partial failure carrying `partial` under the key CloudKit files its
    /// per-item errors on. Keyed by position, because nothing here reads the
    /// item IDs — only the errors behind them.
    init(_ code: Code, partial: [any Error]) {
        let byItemID = Dictionary(
            uniqueKeysWithValues: partial.enumerated().map { ($0.offset as AnyHashable, $0.element) }
        )
        self.init(
            _nsError: NSError(
                domain: CKErrorDomain,
                code: code.rawValue,
                userInfo: [CKPartialErrorsByItemIDKey: byItemID]
            )
        )
    }
}
