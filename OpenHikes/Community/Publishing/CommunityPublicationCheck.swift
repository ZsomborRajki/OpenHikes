//
//  CommunityPublicationCheck.swift
//  OpenHikes
//
//  Where a hike is on the one-way trip from private to published, and the
//  single question this app is able to ask about it.
//
//  Both halves are here rather than on ``Hike`` because both are rules rather
//  than storage: the state is two optional columns read together, and the
//  check is the only thing in the app allowed to write the second one. A suite
//  can exercise either without a `@Model` or a container.
//
//  The state machine and the refresh are ``CommunityUploadState`` and
//  ``CommunityUploadCheck``, which ``CommunityContributionCheck`` shares —
//  read that file for what the app can and cannot know about anything it has
//  uploaded, and for why there are three states rather than four. What is
//  named here is only what is particular to a *hike*: which two columns, which
//  question, and the two things this check can do that a contribution's cannot
//  — ask whether a listing is still there, and forget one that is not.
//

import Foundation
import OpenHikesData
import os
import SwiftData

/// How far along a hike is towards being visible to other people.
///
/// ``CommunityUploadState`` over ``Hike/communitySubmissionID`` and
/// ``Hike/communityListingID``. The listing is the *result* half: a hike can
/// only have one if it was submitted, and it is what a reviewer's yes leaves
/// behind.
nonisolated enum CommunityPublicationState: CommunityUploadState {
    case awaitingReview
    case notShared
    case published

    /// - Parameters:
    ///   - submissionID: ``Hike/communitySubmissionID``.
    ///   - listingID: ``Hike/communityListingID``.
    init(submissionID: String?, listingID: String?) {
        self.init(submissionID: submissionID, resultID: listingID)
    }
}

/// Asks whether a submission has been published, and remembers a yes.
@MainActor
enum CommunityPublicationCheck {
    private static let logger = Logger(subsystem: "OpenHikes", category: "Community")

    /// Brings `hike`'s ``Hike/communityListingID`` up to date, asking at most
    /// one question and only when there is one worth asking.
    ///
    /// ``CommunityUploadCheck/refreshUploadResult(of:submission:result:asking:reportingFailureAs:save:)``
    /// does the work — including staying silent about every failure, and the
    /// two guards that keep a late answer off a newer submission. What is
    /// here is the pair of columns and the question.
    ///
    /// - Parameter save: The commit seam, the same shape ``CommunityPublisher``
    ///   and ``HikeImport`` take theirs in.
    /// - Returns: Whether anything was written, which is what a suite asserts
    ///   on and what the caller uses to avoid asking twice in one launch.
    @discardableResult static func refresh(
        _ hike: Hike,
        transport: any CommunityTransporting,
        save: (ModelContext) throws -> Void = { try $0.save() }
    ) async -> Bool {
        await CommunityUploadCheck.refreshUploadResult(
            of: hike,
            submission: \.communitySubmissionID,
            result: \.communityListingID,
            // Only the id is taken off the listing. Everything else on it is
            // the copy in the public database, which this hike is not.
            asking: { try await transport.publication(of: $0)?.id },
            reportingFailureAs: .init(
                couldNotAsk: "Could not check whether a hike is published",
                couldNotRecord: "Saw a hike go live but could not record it locally"
            ),
            save: save
        )
    }

    /// Whether a listing still exists for `hike`'s submission.
    ///
    /// The same question ``refresh(_:transport:save:)`` asks, pointed the
    /// other way and — the difference that matters — asked because the hiker
    /// tapped rather than because a screen appeared. That is the answer to the
    /// argument in ``Hike/communityListingID`` against re-checking: the cost
    /// that argument refuses is *a request per detail-open forever*, and this
    /// is one request when somebody asks for it. The one-way rule is untouched.
    ///
    /// **A `nil` means taken down here, and does not in `refresh`.** There the
    /// absence of a listing covers a reviewer who has not looked yet and one
    /// who declined, which is why the screen never says *rejected*. Here a
    /// listing was seen at least once — that is what ``Hike/communityListingID``
    /// records — so the only thing its absence can mean is that it went away.
    ///
    /// **Throws where `refresh` stays silent**, and for the reason `refresh`
    /// is silent: nothing asked that one, so a failure was an interruption of
    /// a screen opened to look at a walk. This one was asked, so a failure is
    /// an answer the hiker is owed.
    ///
    /// Writes nothing, deliberately. What comes back is evidence, and
    /// ``forgetPublication(_:save:)`` is the decision that acts on it — split
    /// in two so the screen can confirm before forgetting a listing that a
    /// transient `nil` would otherwise erase on its own.
    static func liveness(
        of hike: Hike,
        transport: any CommunityTransporting
    ) async throws -> Liveness {
        guard let submissionID = hike.communitySubmissionID,
              hike.communityListingID != nil
        else { return .notPublished }

        let listing = try await transport.publication(of: submissionID)

        // The same two races ``refresh`` guards, from the other side. The hike
        // may have been deleted while the request was in flight, or re-shared
        // from another device — and ``Liveness/notPublished`` is the literal
        // truth of both, because a detached hike has no columns left to be
        // about and a re-share cleared the listing itself.
        guard hike.isAttached,
              hike.communitySubmissionID == submissionID,
              hike.communityListingID != nil
        else { return .notPublished }

        return listing == nil ? .takenDown : .live
    }

    /// Forgets that `hike` was ever shared, so a corrected walk can be sent.
    ///
    /// **Both columns, never one.** They are one answer about one submission —
    /// see ``Hike/communityListingID`` — and clearing only the listing would
    /// leave the hike reading *waiting for review* about a submission that is
    /// gone, which is a worse lie than the stale *published* it replaced. It
    /// would also go on blocking a re-record:
    /// ``CommunityPublishingCheck/alreadyShared(in:excluding:)`` fetches
    /// on ``Hike/communitySubmissionID`` alone, so a hike that keeps that
    /// column is still somebody else's retread however dead its listing is.
    ///
    /// What this costs is the two record names a removal request quotes, and
    /// that is the right trade only because of where it is called from: the
    /// listing has just been observed to be gone, so there is nothing left to
    /// ask back and ``CommunityWithdrawal`` needs a record that still exists.
    ///
    /// The photograph columns are left alone. They describe a different pair
    /// of records with their own review, and a contribution outliving the
    /// trail it was aimed at is already a defined state rather than a dangling
    /// reference — see ``CommunityPhotoTarget``.
    ///
    /// - Returns: Whether anything was written, which is what a suite asserts
    ///   on.
    @discardableResult static func forgetPublication(
        _ hike: Hike,
        save: (ModelContext) throws -> Void = { try $0.save() }
    ) -> Bool {
        guard hike.isAttached,
              hike.communitySubmissionID != nil || hike.communityListingID != nil,
              let context = hike.modelContext
        else { return false }

        hike.communitySubmissionID = nil
        hike.communityListingID = nil
        do {
            try save(context)
        } catch {
            // Unlike the cache above, this does not come right on the next
            // launch: nothing re-asks a hike that has no submission id, so a
            // failed save leaves the hike reading *published* until the hiker
            // taps again. Logged rather than swallowed for that reason.
            logger.error(
                """
                Could not forget a hike's publication locally: \
                \(error.localizedDescription, privacy: .public)
                """
            )
            return false
        }
        return true
    }
}

extension CommunityPublicationCheck {
    /// What asking after a published hike's listing came back with.
    ///
    /// Three cases rather than a `Bool`, because *there was nothing to ask* is
    /// a real outcome here: the hike may have been deleted or re-shared while
    /// the request was in flight, and reporting either of those as *taken
    /// down* would invite the screen to clear columns that describe a live
    /// submission.
    nonisolated enum Liveness: Equatable, Sendable {
        /// A listing still points at the submission.
        case live
        /// None does any more, and one did once — see
        /// ``CommunityPublicationCheck/liveness(of:transport:)`` for why that
        /// is unambiguous where the same absence is not in `refresh`.
        case takenDown
        /// This hike is not published, so the question did not apply.
        case notPublished
    }
}
