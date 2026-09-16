//
//  CommunityContributionCheck.swift
//  OpenHikes
//
//  Where a hike's *photographs* are on the trip from private to published,
//  and the single question this app can ask about them.
//
//  The shape is ``CommunityPublicationCheck``'s, applied to the other pair of
//  columns, and the parallel is exact on purpose: three states derived from
//  two optional columns, one question the schema can answer, silence on every
//  failure, and no fourth state for *declined* because a decline leaves
//  nothing behind to observe. A reader who has understood that file has
//  understood this one.
//
//  Two differences are worth naming, and both follow from a contribution being
//  aimed at a hike that already exists.
//
//  **The question is asked of a different type.** A hike asks *is there a
//  listing pointing at my submission*; a contribution asks *is there a
//  contribution record pointing at my photo submission*. Both are queries on a
//  world-readable type keyed on a record name only the author holds — see
//  ``CommunitySchema/Contribution``, whose index argument is
//  ``CommunitySchema/Listing/submission``'s word for word.
//
//  **The answer is a record name and not a listing.** Nothing reads anything
//  else off it: the contribution's own fields are the reviewer's, the
//  photographs are already on this device, and what the app does with the
//  answer is stop offering to send them again. So the transport hands back a
//  `String?` rather than a value, which is the honest size of what is known.
//

import Foundation
import os
import SwiftData

/// How far along a hike's photographs are towards being on somebody else's
/// screen.
///
/// Derived from two columns rather than stored as a third, for the reason
/// ``CommunityPublicationState`` is.
nonisolated enum CommunityContributionState: Equatable, Sendable {
    /// Sent and accepted, with no published contribution seen for it yet.
    /// Covers a reviewer who has not looked and one who declined.
    case awaitingReview
    /// Never sent from this account, so the button is an offer.
    case notShared
    /// A contribution exists. The pictures are on the hike.
    case published

    /// - Parameters:
    ///   - submissionID: ``Hike/communityPhotoSubmissionID``.
    ///   - contributionID: ``Hike/communityPhotoContributionID``.
    init(submissionID: String?, contributionID: String?) {
        // Published first, for the reason ``CommunityPublicationState`` reads
        // the listing first: the second column can only exist because of the
        // first, and reading them the other way round would make a published
        // set with a cleared submission id look unsent.
        if contributionID != nil {
            self = .published
        } else if submissionID != nil {
            self = .awaitingReview
        } else {
            self = .notShared
        }
    }

    /// Whether sending now would put a *second* set of photographs on the same
    /// hike.
    ///
    /// True in both states that have already sent one. The app cannot replace
    /// or withdraw a photo submission any more than it can a hike's — the same
    /// write-once rule, on the same kind of record — so a second send is a
    /// second set beside the first rather than an edit of it, and the form
    /// says so before it will send one.
    var wouldDuplicate: Bool { self != .notShared }
}

/// Asks whether a hiker's contributed photographs have been published, and
/// remembers a yes.
@MainActor
enum CommunityContributionCheck {
    private static let logger = Logger(subsystem: "OpenHikes", category: "Community")

    /// Brings `hike`'s ``Hike/communityPhotoContributionID`` up to date,
    /// asking at most one question and only when there is one worth asking.
    ///
    /// - Parameter save: The commit seam, the same shape every other write in
    ///   this feature takes one in.
    /// - Returns: Whether anything was written.
    @discardableResult static func refresh(
        _ hike: Hike,
        transport: any CommunityTransporting,
        save: (ModelContext) throws -> Void = { try $0.save() }
    ) async -> Bool {
        guard let submissionID = hike.communityPhotoSubmissionID,
              hike.communityPhotoContributionID == nil
        else { return false }

        let contributionID: String?
        do {
            contributionID = try await transport.contribution(of: submissionID)
        } catch {
            logger.debug(
                """
                Could not check whether contributed photos are published: \
                \(error.localizedDescription, privacy: .public)
                """
            )
            return false
        }
        guard let contributionID else { return false }

        // Deleted while the request was in flight, or replaced by a second
        // contribution from another device. Both guards, and both reasons, are
        // ``CommunityPublicationCheck/refresh(_:transport:save:)``'s — a
        // contribution's two columns are one answer about one upload, and
        // writing this one back onto a newer submission would report
        // *published* about pictures no reviewer has seen.
        guard hike.isAttached,
              hike.communityPhotoSubmissionID == submissionID
        else { return false }
        hike.communityPhotoContributionID = contributionID
        guard let context = hike.modelContext else { return false }
        do {
            try save(context)
        } catch {
            logger.error(
                """
                Saw contributed photos go live but could not record it locally: \
                \(error.localizedDescription, privacy: .public)
                """
            )
        }
        return true
    }
}
