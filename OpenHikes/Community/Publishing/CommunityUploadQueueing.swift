//
//  CommunityUploadQueueing.swift
//  OpenHikes
//
//  What this device writes down when an upload landed, and the repair for the
//  case where the review queue was never told about it.
//
//  ``CommunityPublisher/share(_:authorName:transport:excludingPhotos:store:save:)``
//  and ``CommunityPhotoPublisher/contribute(_:to:authorName:transport:excludingPhotos:store:save:)``
//  end the same way — the transport accepted a submission and something has to
//  be remembered — and that used to be written out inline in each. It has two
//  shapes now, because an upload is two saves (see ``CommunityQueueingFailure``
//  for why they are not one): the submission is in the reviewer's queue, or it
//  is uploaded and the queue has not heard. The second needs a repair both
//  senders share, so the bookkeeping lives here once instead of being written
//  twice and drifting.
//
//  ## What is written
//
//  The same three things for both kinds of upload, and the split between them
//  is the design:
//
//  - **The mirrored submission column**, written the moment the upload lands
//    whether or not the queue heard about it. The submission is a real record
//    in a public database either way, and this column is the only handle a
//    hiker has on it — it is what a removal request quotes and what the share
//    button reads to say a hike was sent. Leaving it empty because a *second*
//    request failed is what used to lose the upload.
//  - **The mirrored result column**, cleared beside it, for the reason given
//    where the senders used to do it: the two columns are one answer about one
//    submission, so replacing the name has to drop the answer about the old one.
//  - **The device-local marker** — ``HikeLocalState/unqueuedSubmissionID`` and
//    its photo twin — set only when the notice failed, and cleared when it is
//    saved. It is a note that *this device* still owes the queue a write. It
//    is not mirrored because the debt belongs to the device that holds the
//    staged work; see the column for the argument.
//
//  All three go in one commit, with the photograph stamps, so a launch can
//  never find a submission it remembers without the debt that goes with it.
//
//  ## What is repaired, and what is not
//
//  ``CommunityUploadQueueing/finish(_:hike:transport:save:)`` sends the notice
//  and nothing else. It never rebuilds a draft, never reads a photograph and
//  never calls `submit`, which is the property the whole change exists for: a
//  retry that uploads again is a retry that leaves the first copy behind.
//

import Foundation
import OpenHikesData
import os
import SwiftData

/// Which of a hike's two uploads is being talked about.
///
/// The two are the same machine pointed at different columns, so the
/// bookkeeping here takes the columns as key paths instead of being written
/// twice — the precedent is ``CommunityUploadCheck``, which does the same for
/// the two result checks.
enum CommunityUploadKind {
    /// Photographs contributed to a trail that was already in the list.
    case photos
    /// The hike itself: its route, its details and the pictures that went with
    /// them.
    case route

    /// The mirrored column naming the submission this hike last sent.
    var submission: ReferenceWritableKeyPath<Hike, String?> {
        switch self {
        case .route: \Hike.communitySubmissionID
        case .photos: \Hike.communityPhotoSubmissionID
        }
    }

    /// The mirrored column a reviewer's *yes* is cached in.
    var result: ReferenceWritableKeyPath<Hike, String?> {
        switch self {
        case .route: \Hike.communityListingID
        case .photos: \Hike.communityPhotoContributionID
        }
    }

    /// The device-local note that the queue still has to be told.
    var marker: ReferenceWritableKeyPath<Hike, String?> {
        switch self {
        case .route: \Hike.unqueuedSubmissionID
        case .photos: \Hike.unqueuedPhotoSubmissionID
        }
    }

    /// The submission `hike` still owes a queue entry for, or `nil`.
    ///
    /// Read off the data package's own rule, so the answer a view gets from
    /// ``Hike/pendingCommunityQueueing`` and the answer the repair acts on are
    /// the same question asked twice.
    func pendingSubmissionID(of hike: Hike) -> String? {
        switch self {
        case .route: hike.pendingCommunityQueueing
        case .photos: hike.pendingCommunityPhotoQueueing
        }
    }

    /// The upload `hike` is still carrying a debt for, if it is carrying one.
    ///
    /// The route is asked first. It is the older and larger of the two, and
    /// the finish form for it is the one a hiker was last in; the photographs'
    /// turn comes the moment it is settled, because the button re-reads this on
    /// every change to the hike.
    static func unfinished(of hike: Hike) -> Self? {
        if Self.route.pendingSubmissionID(of: hike) != nil { return .route }
        if Self.photos.pendingSubmissionID(of: hike) != nil { return .photos }
        return nil
    }
}

@MainActor
enum CommunityUploadQueueing {
    private static let logger = Logger(subsystem: "OpenHikes", category: "Community")

    /// Writes down that an upload reached the public database, in one commit.
    ///
    /// - Parameters:
    ///   - kind: Which pair of columns the upload belongs to.
    ///   - submissionID: What the transport named the submission.
    ///   - photoIDs: The pictures whose files actually left the device.
    ///   - queueingFailure: Why the review notice was not saved, or `nil` when
    ///     it was. Everything else is recorded the same either way.
    ///   - hike: The hike the upload was made from. It may have been deleted
    ///     while the request was in flight — a share is a long wait and the
    ///     list is one tap away — in which case the submission stands and there
    ///     is simply nothing left to remember it on.
    ///   - save: The commit seam. A failure is logged and not reported: the
    ///     submission is real, so this is not a failed send, and what is lost
    ///     is only the device's memory of it.
    /// - Returns: What the sender should report — ``CommunitySendOutcome/submitted``
    ///   when the queue heard about it, and ``CommunitySendOutcome/uploadedNotQueued(_:)``
    ///   when it did not.
    static func record(
        _ kind: CommunityUploadKind,
        submissionID: String,
        photoIDs: [UUID],
        queueingFailure: CommunityFailure?,
        on hike: Hike,
        save: (ModelContext) throws -> Void
    ) -> CommunitySendOutcome {
        let outcome: CommunitySendOutcome = queueingFailure.map { .uploadedNotQueued($0) } ?? .submitted
        // Only now that the upload landed is anything written down. Writing the
        // submission column first would make a failed upload look like a
        // successful one for good, with no way back, since this app cannot
        // query its own submissions to find out.
        guard hike.isAttached else { return outcome }
        hike[keyPath: kind.submission] = submissionID
        // Both mirrored columns, together, because they describe one
        // submission between them: the result column caches an answer about
        // whichever submission the other names, and the moment that name
        // changes the cached answer is about an upload nobody is asking after
        // any more. Leaving it would say *published* about a copy no reviewer
        // has seen and — worse, because it is silent — the publication check
        // skips a hike that already has a result, so the new submission would
        // never be asked about at all.
        //
        // The listing itself is untouched by this; a published hike stays
        // published and stays findable. What is cleared is only this device's
        // record of it, which is what the share form promises when it says
        // the published copy stays as it is.
        hike[keyPath: kind.result] = nil
        setMarker(queueingFailure == nil ? nil : submissionID, of: kind, on: hike)
        // In the same commit, and for a version of the same reason: these
        // stamps say which pictures are now in the public database, and a hike
        // whose submission was recorded without them would offer every one of
        // them again as though it were new. They are written when only the
        // queue write failed as well, because the pictures did leave the
        // device, and the repair must not be a second chance to send them.
        CommunityPublisher.markSent(photoIDs, on: hike)
        commit(hike, save: save, failureMessage: "Sent an upload but could not record it locally")
        return outcome
    }

    /// Puts an upload that landed but never reached the review queue in front of
    /// a reviewer, without uploading anything again.
    ///
    /// The order matters, and each step is there for a case that was reasoned
    /// about rather than hoped for:
    ///
    /// 1. **Restore the mirrored column if only the marker survived.** The
    ///    marker is written in the same commit as the column, but the two are
    ///    in different stores and a commit across them is not atomic. A device
    ///    killed between them can hold the marker alone, and the marker is
    ///    self-sufficient — see ``CommunityQueueingMarker``.
    /// 2. **Ask whether it was published after all.** A notice save whose
    ///    answer never arrived may have landed, and a reviewer may have acted
    ///    on it. Saving a second notice for a submission somebody already
    ///    published would put it back in front of them, and for photographs
    ///    nothing on the reviewer's side notices — see
    ///    ``CommunityTransporting/reviewQueue()``. The check is best-effort
    ///    and silent, as every check here is; what it cannot settle, the
    ///    deterministic notice name does.
    /// 3. **Save the notice.** Only that; see
    ///    ``CommunityTransporting/queueForReview(submissionID:)``.
    ///
    /// - Returns: ``CommunitySendOutcome/submitted`` when there is nothing left
    ///   to do, ``CommunitySendOutcome/uploadedNotQueued(_:)`` when the notice
    ///   still could not be saved — the marker stays, so the hiker can try
    ///   again, on this launch or a later one — and
    ///   ``CommunitySendOutcome/refused(_:)`` when the submission is no longer
    ///   there to queue.
    static func finish(
        _ kind: CommunityUploadKind,
        hike: Hike,
        transport: any CommunityTransporting,
        save: (ModelContext) throws -> Void
    ) async -> CommunitySendOutcome {
        guard hike.isAttached else { return .refused(.noLongerAvailable) }
        guard let submissionID = kind.pendingSubmissionID(of: hike) else { return .submitted }

        if hike[keyPath: kind.submission] == nil {
            hike[keyPath: kind.submission] = submissionID
            commit(hike, save: save, failureMessage: "Restored an upload's name but could not record it locally")
        }

        await askWhetherSeen(kind, hike: hike, transport: transport, save: save)
        guard hike.isAttached else { return .refused(.noLongerAvailable) }
        // A result means a reviewer was shown it, which means the queue heard
        // about it however this device last found out; a different submission
        // means the debt this device was carrying has been superseded. Either
        // way there is nothing left to send, and the marker is stale.
        guard kind.pendingSubmissionID(of: hike) == submissionID else {
            clearMarker(of: kind, for: submissionID, on: hike)
            commit(hike, save: save, failureMessage: "Settled an upload's queue entry but could not record it locally")
            return .submitted
        }

        do {
            try await queue(kind, submissionID: submissionID, through: transport)
        } catch {
            let failure = CommunityFailure(error)
            if failure == .noLongerAvailable {
                abandon(kind, submissionID: submissionID, on: hike, save: save)
                return .refused(failure)
            }
            logger.error("Could not queue an upload for review: \(failure.localizedDescription, privacy: .public)")
            return .uploadedNotQueued(failure)
        }

        // The hike may have been deleted while the request was in flight; the
        // notice is saved either way, and there is nothing here to settle.
        guard hike.isAttached else { return .submitted }
        clearMarker(of: kind, for: submissionID, on: hike)
        commit(hike, save: save, failureMessage: "Queued an upload for review but could not record it locally")
        return .submitted
    }

    // MARK: - Steps

    /// Asks the check this kind of upload already has whether a reviewer got as
    /// far as acting on it, and lets it write the answer down.
    private static func askWhetherSeen(
        _ kind: CommunityUploadKind,
        hike: Hike,
        transport: any CommunityTransporting,
        save: (ModelContext) throws -> Void
    ) async {
        switch kind {
        case .route: await CommunityPublicationCheck.refresh(hike, transport: transport, save: save)
        case .photos: await CommunityContributionCheck.refresh(hike, transport: transport, save: save)
        }
    }

    private static func queue(
        _ kind: CommunityUploadKind,
        submissionID: String,
        through transport: any CommunityTransporting
    ) async throws {
        switch kind {
        case .route: try await transport.queueForReview(submissionID: submissionID)
        case .photos: try await transport.queuePhotosForReview(submissionID: submissionID)
        }
    }

    /// Lets go of an upload whose submission is no longer there.
    ///
    /// A reviewer's decline deletes the submission, and so does a takedown, and
    /// a notice that points at a record that is gone cannot be saved. Nothing
    /// can be queued then and nothing is owed, so the marker goes — and the
    /// mirrored column with it, because left in place it would read *waiting
    /// for review* about a record that does not exist and refuse a fresh share
    /// as a duplicate of it. The result column is already empty: a marker with
    /// a result beside it is stale and never reaches here.
    private static func abandon(
        _ kind: CommunityUploadKind,
        submissionID: String,
        on hike: Hike,
        save: (ModelContext) throws -> Void
    ) {
        guard hike.isAttached else { return }
        // Only if it is still the name this repair was about: a re-send from
        // another device may have replaced it while the request was out.
        if hike[keyPath: kind.submission] == submissionID {
            hike[keyPath: kind.submission] = nil
        }
        clearMarker(of: kind, for: submissionID, on: hike)
        commit(hike, save: save, failureMessage: "Dropped a vanished upload but could not record it locally")
    }

    // MARK: - The marker

    /// Writes the marker only when it would change.
    ///
    /// Reading is free and writing is not: the passthrough creates the
    /// device-local row on its first write, so clearing a marker that was never
    /// set would leave a row behind for every hike ever shared.
    private static func setMarker(_ value: String?, of kind: CommunityUploadKind, on hike: Hike) {
        guard hike[keyPath: kind.marker] != value else { return }
        hike[keyPath: kind.marker] = value
    }

    /// Clears the marker, but only if it is still the one this repair was
    /// about — a re-send may have written a newer one while the request was in
    /// flight, and that one is somebody else's debt.
    private static func clearMarker(
        of kind: CommunityUploadKind,
        for submissionID: String,
        on hike: Hike
    ) {
        guard hike[keyPath: kind.marker] == submissionID else { return }
        hike[keyPath: kind.marker] = nil
    }

    private static func commit(
        _ hike: Hike,
        save: (ModelContext) throws -> Void,
        failureMessage: String
    ) {
        guard let context = hike.modelContext else { return }
        do {
            try save(context)
        } catch {
            logger.error(
                """
                \(failureMessage, privacy: .public): \
                \(error.localizedDescription, privacy: .public)
                """
            )
        }
    }
}

extension CommunityPublisher {
    /// Finishes sending a hike that was uploaded but never reached the review
    /// queue — only the missing write, and nothing is uploaded again.
    ///
    /// What ``CommunityPublisher/share(_:authorName:transport:excludingPhotos:store:save:)``
    /// leaves behind when it returns ``CommunitySendOutcome/uploadedNotQueued(_:)``
    /// and what a hike still carries after a relaunch, so the same call serves
    /// the form that was open and the one opened a week later.
    ///
    /// - Parameter save: The commit seam, the same shape every other write in
    ///   this feature takes one in.
    @MainActor
    static func finishQueueing(
        _ hike: Hike,
        transport: any CommunityTransporting,
        save: (ModelContext) throws -> Void = { try $0.save() }
    ) async -> CommunitySendOutcome {
        await CommunityUploadQueueing.finish(.route, hike: hike, transport: transport, save: save)
    }
}

extension CommunityPhotoPublisher {
    /// Finishes sending contributed photographs that were uploaded but never
    /// reached the review queue — ``CommunityPublisher/finishQueueing(_:transport:save:)``
    /// for the other pair of columns.
    @MainActor
    static func finishQueueing(
        _ hike: Hike,
        transport: any CommunityTransporting,
        save: (ModelContext) throws -> Void = { try $0.save() }
    ) async -> CommunitySendOutcome {
        await CommunityUploadQueueing.finish(.photos, hike: hike, transport: transport, save: save)
    }
}
