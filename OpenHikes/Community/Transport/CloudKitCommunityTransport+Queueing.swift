//
//  CloudKitCommunityTransport+Queueing.swift
//  OpenHikes
//
//  The write that puts an uploaded submission in front of a reviewer.
//
//  One type with `CloudKitCommunityTransport.swift`, split out of the review
//  and photo files because both kinds of submission are queued through the
//  same code and the argument for it belongs in one place. See
//  `CommunityQueueing.swift` for how the two saves of an upload fit together
//  and what a failure of the second one is meant to leave behind.
//

import CloudKit
import Foundation
import os

nonisolated extension CloudKitCommunityTransport {

    /// The seam for a suite: a transport whose two saves go through `writer`
    /// instead of the public database.
    ///
    /// An upload reads `writer` and never ``database``, so a suite that drives
    /// only ``submit(_:)``, ``submitPhotos(_:)`` and the two queue writes
    /// reaches CloudKit through no path at all. The queries still read
    /// ``database``, and a suite that calls one is calling the real public
    /// one, which no suite may. It is here rather than beside
    /// ``init(containerIdentifier:)`` because a struct body this long has no
    /// room for a second initializer, and for no deeper reason.
    init(writer: any CommunityRecordWriting) {
        containerIdentifier = CloudSyncCoordinator.containerIdentifier
        self.writer = writer
    }

    /// ``queueForReview(submissionID:)`` for a hike this call has just
    /// uploaded.
    ///
    /// The same save, with one difference: a failure arrives as
    /// ``CommunityQueueingFailure``, which carries the submission's name. The
    /// caller of ``submit(_:)`` has not been handed that name yet, and a
    /// failure that dropped it would leave an upload nobody can queue.
    @concurrent
    func queueUploadedHike(submissionID: String) async throws {
        do {
            try await queueForReview(submissionID: submissionID)
        } catch {
            throw CommunityQueueingFailure(submissionID: submissionID, failure: CommunityFailure(error))
        }
    }

    /// ``queuePhotosForReview(submissionID:)`` for photographs this call has
    /// just uploaded, failing the way ``queueUploadedHike(submissionID:)`` does.
    @concurrent
    func queueUploadedPhotos(submissionID: String) async throws {
        do {
            try await queuePhotosForReview(submissionID: submissionID)
        } catch {
            throw CommunityQueueingFailure(submissionID: submissionID, failure: CommunityFailure(error))
        }
    }

    /// Puts an uploaded hike submission in the reviewer's queue.
    ///
    /// Called by ``submit(_:)`` straight after the upload, and by a repair
    /// when that call failed — the same code for both, so a retry cannot
    /// differ from the first attempt in any way that matters. It saves one
    /// record and touches nothing that was uploaded.
    ///
    /// Awaited and thrown rather than logged because a submission that never
    /// reaches the queue is not *waiting*, it is unreachable. Nothing
    /// enumerates submissions, by design, so no query can find one afterwards
    /// and no reviewer will ever be shown it, while the hiker has been told it
    /// was sent. That is the one outcome worth failing a share over.
    ///
    /// Safe to call more than once for the same submission. See
    /// ``saveNotice(forSubmission:through:while:)``.
    @concurrent
    func queueForReview(submissionID: String) async throws {
        try await saveNotice(
            forSubmission: submissionID,
            through: CommunitySchema.Notice.submission,
            while: "queueing a hike for review"
        )
    }

    /// Puts an uploaded set of contributed photographs in the reviewer's
    /// queue.
    ///
    /// The same notice type a hike's submission is queued through, with the
    /// other reference field set — see ``CommunitySchema/Notice`` for why one
    /// type carries both.
    @concurrent
    func queuePhotosForReview(submissionID: String) async throws {
        try await saveNotice(
            forSubmission: submissionID,
            through: CommunitySchema.Notice.photoSubmission,
            while: "queueing photos for review"
        )
    }

    /// Saves the notice for one submission, treating one that is already
    /// there as done.
    ///
    /// The notice is named after its submission
    /// (``CommunitySchema/Notice/recordName(forSubmission:)``), so a second
    /// save is a collision rather than a second notice. That is what makes the
    /// call repeatable: a save whose answer never arrived has usually
    /// happened, and asking again must end with one entry in the queue, not
    /// two. CloudKit reports the collision as `serverRecordChanged`, and this
    /// reads that as *queued*.
    ///
    /// **That reading is an assumption nothing here can check**, because an
    /// author cannot read a notice back — which is the point of the schema.
    /// It rests on a save with no change tag being an insert, and an insert
    /// of a name that exists being the one error with that code. If the
    /// server answered a permission failure there instead, a retry after an
    /// ambiguous save would report a failure for a notice that is in fact
    /// queued. That is the safe way to be wrong — it uploads nothing and
    /// queues nothing twice, and the hike goes on offering to finish — and
    /// `permissionFailure` is deliberately *not* read as success: a notice
    /// type whose create grant had been lost would then look like a working
    /// queue, which is the silent stranding this exists to end.
    ///
    /// The record name goes into the log when the save fails, for the reason
    /// it always did: it is what a notice could be written *by hand* from,
    /// should the device that holds the retry be lost.
    private func saveNotice(
        forSubmission submissionID: String,
        through field: String,
        while reason: String
    ) async throws {
        let noticeID = CKRecord.ID(
            recordName: CommunitySchema.Notice.recordName(forSubmission: submissionID)
        )
        let notice = CKRecord(recordType: CommunitySchema.noticeType, recordID: noticeID)
        notice[field] = CKRecord.Reference(
            // `.deleteSelf` rather than `.none`, so the queue cannot outlive
            // what it points at: deleting a submission — which is what
            // declining one is — takes its notice with it, server-side, with
            // no second request to fail. See ``decline(_:)``.
            recordID: CKRecord.ID(recordName: submissionID),
            action: .deleteSelf
        )
        do {
            _ = try await writer.save(notice)
        } catch where Self.isAlreadyQueued(error, noticeID: noticeID) {
            Self.logger.info(
                "The notice for a submission was already saved: \(submissionID, privacy: .public)"
            )
        } catch {
            Self.logger.error(
                """
                Uploaded a submission but could not queue it for review. \
                The app offers to finish sending it; if that device is lost it \
                can be queued by hand from this name: \(submissionID, privacy: .public)
                """
            )
            throw Self.noticeFailure(from: error, while: reason)
        }
    }

    /// ``failure(from:while:)`` for a notice, which differs in one answer.
    ///
    /// A refused save is ``CommunityFailure/notPermitted`` to the generic
    /// mapping, and that case says *this account can’t review submissions* —
    /// a sentence about the reviewer’s screen, which is the only place it was
    /// ever meant to reach. A hiker finishing their own upload who read it
    /// would be told they lack a role they never needed. What happened to them
    /// is that the queue would not take the notice, and the honest thing to
    /// say about that is what is said about every other refusal they can do
    /// nothing about: try again.
    static func noticeFailure(from error: any Error, while reason: String) -> CommunityFailure {
        let mapped = Self.failure(from: error, while: reason)
        guard mapped == .notPermitted else { return mapped }
        return .unavailable(error.localizedDescription)
    }

    /// Whether a failed save of a notice means the notice is already there.
    ///
    /// `serverRecordChanged` is what CloudKit answers when a record is saved
    /// as new and a record of that name exists. A save of one record is
    /// normally reported as that error directly, and a batch wraps it in a
    /// `partialFailure` keyed by the record — both are read the same way.
    static func isAlreadyQueued(_ error: any Error, noticeID: CKRecord.ID) -> Bool {
        guard let ckError = error as? CKError else { return false }
        switch ckError.code {
        case .serverRecordChanged:
            return true
        case .partialFailure:
            let inner = ckError.partialErrorsByItemID?[noticeID] as? CKError
            return inner?.code == .serverRecordChanged
        default:
            return false
        }
    }
}
