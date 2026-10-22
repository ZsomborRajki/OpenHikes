//
//  Hike+CommunityQueueing.swift
//  OpenHikesData
//
//  When the device-local "this upload still has to be queued for review"
//  markers still count — a rule, kept apart from the two columns it reads so
//  that a suite can ask it without a store.
//
//  The markers are ``HikeLocalState/unqueuedSubmissionID`` and
//  ``HikeLocalState/unqueuedPhotoSubmissionID``; what they are and why they
//  are not mirrored is on the first of them. What is here is only the other
//  half of the question: a marker is a note that was true when it was written,
//  the mirrored columns beside it keep moving, and a note that disagrees with
//  them is the one to distrust.
//

import Foundation

/// The rule for when an unqueued-submission marker still means anything.
nonisolated public enum CommunityQueueingMarker {
    /// The submission a hike still owes a review-queue entry for, or `nil`
    /// when there is nothing to finish.
    ///
    /// A marker is **stale**, and ignored, in two cases — and ignored rather
    /// than trusted-then-repaired, because the alternative is a prompt to
    /// finish sending something that is not the hiker's to finish:
    ///
    /// - **A result has been seen.** A listing, or a contribution, exists
    ///   only because a reviewer was shown the submission, which means it is
    ///   in the queue however this device last heard about it. Another device
    ///   can have reached that point first, because both columns it is read
    ///   from are mirrored and the marker is not.
    /// - **A different submission has replaced it.** A re-send writes its own
    ///   name into the mirrored column, and a marker for the one before it
    ///   describes a record nobody is waiting on. Sending the missing notice
    ///   for it would put an abandoned upload in front of a reviewer beside
    ///   the one that replaced it.
    ///
    /// The mirrored submission column being *empty* does not make a marker
    /// stale. That is the half-written state — the upload landed and this
    /// device died between remembering it in one store and in the other — and
    /// the marker, which is written first and is self-sufficient, is the only
    /// thing left that knows the submission exists.
    ///
    /// - Parameters:
    ///   - marker: The device-local marker.
    ///   - submissionID: The mirrored column naming the submission this hike
    ///     last sent.
    ///   - resultID: The mirrored column a reviewer's *yes* is written to.
    public static func pendingID(
        marker: String?,
        submissionID: String?,
        resultID: String?
    ) -> String? {
        guard let marker, resultID == nil else { return nil }
        guard submissionID == nil || submissionID == marker else { return nil }
        return marker
    }
}

public extension Hike {
    /// The hike submission this device still has to put in front of a
    /// reviewer, or `nil` — see ``CommunityQueueingMarker/pendingID(marker:submissionID:resultID:)``
    /// for when the marker is allowed to count.
    var pendingCommunityQueueing: String? {
        CommunityQueueingMarker.pendingID(
            marker: unqueuedSubmissionID,
            submissionID: communitySubmissionID,
            resultID: communityListingID
        )
    }

    /// The contributed photographs this device still has to put in front of a
    /// reviewer, or `nil` — the photo half of ``pendingCommunityQueueing``.
    var pendingCommunityPhotoQueueing: String? {
        CommunityQueueingMarker.pendingID(
            marker: unqueuedPhotoSubmissionID,
            submissionID: communityPhotoSubmissionID,
            resultID: communityPhotoContributionID
        )
    }
}
