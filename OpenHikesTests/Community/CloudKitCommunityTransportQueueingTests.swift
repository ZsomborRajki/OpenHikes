//
//  CloudKitCommunityTransportQueueingTests.swift
//  OpenHikesTests
//
//  The two saves an upload is made of, and what the app is left holding when
//  only the second of them fails.
//

import CloudKit
import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import Testing

/// An upload is two independent saves: the submission, which carries every
/// asset, then the notice that puts it in front of a reviewer. CloudKit has no
/// transaction across them, so the failure that matters is the one between
/// them — the submission is already in the public database and the notice is
/// not.
///
/// These suites run the real transport over a scripted writer, because the
/// boundary under test is inside it. A stub standing in for the whole
/// transport can refuse an upload or accept one; it cannot refuse the second
/// save and let the first land.
@MainActor
@Suite("Community upload queueing (transport)")
struct CloudKitCommunityTransportQueueingTests {
    private static let target = CommunityPhotoTarget(
        listingID: "listing-1",
        title: "Almbachklamm",
        authorName: "Anna"
    )

    /// A scratch directory for one test, with the two places an upload touches
    /// beneath it: where the transport stages the route and the pins, and where
    /// the photographs a draft names already are.
    private struct Scratch {
        let root: URL

        var staging: URL { root.appendingPathComponent("staging", isDirectory: true) }
        var photos: URL { root.appendingPathComponent("photos", isDirectory: true) }

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("community-queueing-\(UUID().uuidString)", isDirectory: true)
            for directory in [staging, photos] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func routeDraft(in scratch: Scratch) -> CommunitySubmissionDraft {
        CommunitySubmissionDraft(
            hikeID: UUID(),
            title: "Ridge Loop",
            authorName: "Anna",
            trackDescription: nil,
            hikeDate: .now,
            distanceMeters: 1000,
            route: Fixture.ridgeRoute,
            photoPins: [],
            photoFileURLs: [],
            stagingDirectory: scratch.staging
        )
    }

    private func photoDraft(in scratch: Scratch) throws -> CommunityPhotoDraft {
        let photo = scratch.photos.appendingPathComponent("photo-0.jpg")
        try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: photo)
        return CommunityPhotoDraft(
            target: Self.target,
            hikeID: UUID(),
            authorName: "Bern",
            takenOn: .now,
            photoPins: [CommunityPhotoPin(capturedAt: .now, coordinate: nil)],
            photoFileURLs: [photo],
            stagingDirectory: scratch.staging
        )
    }

    // MARK: The first save lands, the second does not

    /// The case the issue is about. By the time the notice is attempted the
    /// submission is a record in the public database, so the failure has to say
    /// *which* one. A bare "failed" is what let a retry upload a second copy
    /// under a new name and leave the first outside the review queue for good.
    @Test("a hike whose notice fails reports the submission that did land")
    func routeNoticeFailureNamesTheSubmission() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let draft = routeDraft(in: scratch)
        let writer = ScriptedRecordWriter(script: [nil, CKError(.networkUnavailable)])
        let transport = CloudKitCommunityTransport(writer: writer)

        let failure = await #expect(throws: CommunityQueueingFailure.self) {
            try await transport.submit(draft)
        }

        let saved = writer.saved
        #expect(saved.map(\.recordType) == [CommunitySchema.submissionType, CommunitySchema.noticeType])
        #expect(saved.first?.assetFields.contains(CommunitySchema.Submission.route) == true)
        #expect(failure?.submissionID == saved.first?.recordName)
        #expect(failure?.failure == .unreachable)
    }

    @Test("a contribution whose notice fails reports the submission that did land")
    func photoNoticeFailureNamesTheSubmission() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let draft = try photoDraft(in: scratch)
        let writer = ScriptedRecordWriter(script: [nil, CKError(.serviceUnavailable)])
        let transport = CloudKitCommunityTransport(writer: writer)

        let failure = await #expect(throws: CommunityQueueingFailure.self) {
            try await transport.submitPhotos(draft)
        }

        let saved = writer.saved
        #expect(saved.map(\.recordType) == [CommunitySchema.photoSubmissionType, CommunitySchema.noticeType])
        #expect(saved.first?.assetFields.contains(CommunitySchema.PhotoSubmission.photos) == true)
        #expect(failure?.submissionID == saved.first?.recordName)
        #expect(failure?.failure == .unreachable)
    }

    /// The notice a failed upload leaves unwritten is the one a repair writes,
    /// so what the first attempt would have saved is worth pinning too: it
    /// names the right record, through the right field, and carries no asset.
    @Test("an upload that goes through queues itself in the same call")
    func uploadQueuesItself() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let writer = ScriptedRecordWriter()
        let transport = CloudKitCommunityTransport(writer: writer)

        let submissionID = try await transport.submit(routeDraft(in: scratch))

        let saved = writer.saved
        #expect(saved.map(\.recordType) == [CommunitySchema.submissionType, CommunitySchema.noticeType])
        #expect(submissionID == saved.first?.recordName)
        #expect(saved.last?.recordName == CommunitySchema.Notice.recordName(forSubmission: submissionID))
        #expect(saved.last?.references == [CommunitySchema.Notice.submission: submissionID])
        #expect(saved.last?.assetFields.isEmpty == true)
    }

    /// Nothing was uploaded, so there is nothing to name, and nothing to
    /// finish later: this has to stay the ordinary failure it always was,
    /// not a ``CommunityQueueingFailure`` that would send the hiker looking for
    /// a submission that does not exist.
    @Test("a submission that does not upload is an ordinary failure with no notice behind it")
    func failedSubmissionLeavesNothingToQueue() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let draft = routeDraft(in: scratch)
        let writer = ScriptedRecordWriter(script: [CKError(.networkUnavailable)])
        let transport = CloudKitCommunityTransport(writer: writer)

        let failure = await #expect(throws: CommunityFailure.self) {
            try await transport.submit(draft)
        }

        #expect(failure == .unreachable)
        #expect(writer.saved.map(\.recordType) == [CommunitySchema.submissionType])
    }

    @Test("a signed-out upload saves nothing")
    func signedOutSavesNothing() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let draft = routeDraft(in: scratch)
        let writer = ScriptedRecordWriter(accountStatus: .noAccount)
        let transport = CloudKitCommunityTransport(writer: writer)

        let failure = await #expect(throws: CommunityFailure.self) {
            try await transport.submit(draft)
        }

        #expect(failure == .notSignedIn)
        #expect(writer.saved.isEmpty)
    }

    // MARK: Finishing what was started

    /// What the retry is: one record, the notice, and nothing the first save
    /// already carried. A retry that uploaded the route again would be the
    /// original bug with a longer name.
    @Test("finishing a hike saves the notice and uploads nothing")
    func routeRepairSavesOnlyTheNotice() async throws {
        let writer = ScriptedRecordWriter()
        let transport = CloudKitCommunityTransport(writer: writer)

        try await transport.queueForReview(submissionID: "submission-7")

        let saved = writer.saved
        #expect(saved.count == 1)
        #expect(saved.first?.recordType == CommunitySchema.noticeType)
        #expect(saved.first?.recordName == CommunitySchema.Notice.recordName(forSubmission: "submission-7"))
        #expect(saved.first?.references == [CommunitySchema.Notice.submission: "submission-7"])
        #expect(saved.first?.assetFields.isEmpty == true)
    }

    /// The same repair for the other kind, which points through the other
    /// field: a photo notice that used the route's would queue nothing a
    /// reviewer's screen could open.
    @Test("finishing a contribution saves the notice through the photo field")
    func photoRepairSavesOnlyTheNotice() async throws {
        let writer = ScriptedRecordWriter()
        let transport = CloudKitCommunityTransport(writer: writer)

        try await transport.queuePhotosForReview(submissionID: "photo-submission-7")

        let saved = writer.saved
        #expect(saved.count == 1)
        #expect(saved.first?.recordType == CommunitySchema.noticeType)
        #expect(saved.first?.references == [CommunitySchema.Notice.photoSubmission: "photo-submission-7"])
        #expect(saved.first?.assetFields.isEmpty == true)
    }

    /// The notice's name is derived from the submission's, so a retry after an
    /// ambiguous answer — the save arrived and the reply did not — lands on the
    /// record that may already be there instead of queueing the submission a
    /// second time. For a photo submission a second notice is worse than
    /// untidy: a reviewer could publish the same set twice.
    @Test("every attempt at one submission's notice names the same record")
    func noticeNameIsDeterministic() async throws {
        let writer = ScriptedRecordWriter()
        let transport = CloudKitCommunityTransport(writer: writer)

        try await transport.queueForReview(submissionID: "submission-7")
        try await transport.queueForReview(submissionID: "submission-7")
        try await transport.queueForReview(submissionID: "submission-8")

        let names = writer.saved.map(\.recordName)
        #expect(names.count == 3)
        #expect(names[0] == names[1])
        #expect(names[1] != names[2])
    }

    /// CloudKit answers a save of a record name that already exists, with no
    /// change tag, as a conflict. Here that is the answer to "was it queued
    /// already?", and the answer is yes — so it ends the repair rather than
    /// failing it, and a hiker whose first attempt landed unseen is not left
    /// pressing a button that can never succeed.
    @Test("a notice that is already there counts as queued")
    func existingNoticeCountsAsQueued() async throws {
        let writer = ScriptedRecordWriter(script: [CKError(.serverRecordChanged)])
        let transport = CloudKitCommunityTransport(writer: writer)

        try await transport.queueForReview(submissionID: "submission-7")

        #expect(writer.saved.count == 1)
    }

    /// The same conflict as the save reports it when it travels in a batch: the
    /// outer error is a partial failure and the conflict is filed under the
    /// record it is about.
    @Test("a conflict reported inside a partial failure counts as queued too")
    func existingNoticeInsidePartialFailureCountsAsQueued() async throws {
        let noticeID = CKRecord.ID(recordName: CommunitySchema.Notice.recordName(forSubmission: "photo-submission-7"))
        let writer = ScriptedRecordWriter(script: [
            CKError.partialFailure(CKError(.serverRecordChanged), for: noticeID)
        ])
        let transport = CloudKitCommunityTransport(writer: writer)

        try await transport.queuePhotosForReview(submissionID: "photo-submission-7")

        #expect(writer.saved.count == 1)
    }

    /// A refusal is *not* read as "already queued", though it would be the
    /// convenient reading. Only a reviewer may read a notice, so the server
    /// cannot say whether one exists to somebody who may only create them, and
    /// guessing yes would tell a hiker their upload is in the queue on the
    /// strength of nothing.
    @Test("a refused notice is an outage, not a claim about who may review")
    func refusedNoticeIsNotTheReviewerSentence() async throws {
        let writer = ScriptedRecordWriter(script: [CKError(.permissionFailure)])
        let transport = CloudKitCommunityTransport(writer: writer)

        let failure = await #expect(throws: CommunityFailure.self) {
            try await transport.queueForReview(submissionID: "submission-7")
        }

        guard case .unavailable? = failure else {
            Issue.record("expected .unavailable, got \(String(describing: failure))")
            return
        }
    }

    /// The notice's reference is `deleteSelf`, so CloudKit refuses one for a
    /// submission a reviewer has since deleted. The hike has to hear that the
    /// upload is gone, which is a thing it can act on, rather than that the
    /// network is down, which would have it retrying for good.
    @Test("a notice for a submission that no longer exists says so")
    func vanishedSubmissionIsReported() async throws {
        let writer = ScriptedRecordWriter(script: [CKError(.referenceViolation)])
        let transport = CloudKitCommunityTransport(writer: writer)

        let failure = await #expect(throws: CommunityFailure.self) {
            try await transport.queueForReview(submissionID: "submission-7")
        }

        #expect(failure == .noLongerAvailable)
    }
}

private extension CKError {
    init(_ code: Code) {
        self.init(_nsError: NSError(domain: CKErrorDomain, code: code.rawValue))
    }

    /// What CloudKit throws for a batch where some records failed: an outer
    /// error carrying each record's own, keyed by its ID.
    static func partialFailure(_ inner: CKError, for recordID: CKRecord.ID) -> CKError {
        Self(_nsError: NSError(
            domain: CKErrorDomain,
            code: Code.partialFailure.rawValue,
            userInfo: [CKPartialErrorsByItemIDKey: [recordID: inner]]
        ))
    }
}
