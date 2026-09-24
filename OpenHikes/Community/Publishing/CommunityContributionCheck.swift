//
//  CommunityContributionCheck.swift
//  OpenHikes
//
//  Where a hike's *photographs* are on the trip from private to published, and
//  the single question this app can ask about them.
//
//  The machine is ``CommunityUploadState`` and ``CommunityUploadCheck``, the
//  same one ``CommunityPublicationCheck`` uses — three states derived from two
//  optional columns, one question the schema can answer, silence on every
//  failure, and no fourth state for *declined* because a decline leaves
//  nothing behind to observe. Read that file for the argument; a reader who
//  has understood it has understood this one, which is now true in code rather
//  than by maintenance.
//
//  Two differences are worth naming here, and both follow from a contribution
//  being aimed at a hike that already exists.
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
//  `String?` rather than a value, which is the honest size of what is known —
//  and is why this half needs no `?.id` where the hike's does.
//

import Foundation
import OpenHikesData
import SwiftData

/// How far along a hike's photographs are towards being on somebody else's
/// screen.
///
/// ``CommunityUploadState`` over ``Hike/communityPhotoSubmissionID`` and
/// ``Hike/communityPhotoContributionID``. The contribution is the *result*
/// half, for the reason a listing is one.
///
/// Its own type rather than ``CommunityPublicationState`` under another name:
/// a hike carries both at once — ``HikeDetailView+Community`` reads them side
/// by side — and one type for the pair would let the two be passed the wrong
/// way round.
nonisolated enum CommunityContributionState: CommunityUploadState {
    case awaitingReview
    case notShared
    case published

    /// - Parameters:
    ///   - submissionID: ``Hike/communityPhotoSubmissionID``.
    ///   - contributionID: ``Hike/communityPhotoContributionID``.
    init(submissionID: String?, contributionID: String?) {
        self.init(submissionID: submissionID, resultID: contributionID)
    }
}

/// Asks whether a hiker's contributed photographs have been published, and
/// remembers a yes.
@MainActor
enum CommunityContributionCheck {
    /// Brings `hike`'s ``Hike/communityPhotoContributionID`` up to date,
    /// asking at most one question and only when there is one worth asking.
    ///
    /// ``CommunityUploadCheck/refreshUploadResult(of:submission:result:asking:reportingFailureAs:save:)``
    /// does the work, including the two guards against a late answer landing
    /// on a newer submission — a contribution's two columns are one answer
    /// about one upload, and writing this one back onto a newer submission
    /// would report *published* about pictures no reviewer has seen.
    ///
    /// - Parameter save: The commit seam, the same shape every other write in
    ///   this feature takes one in.
    /// - Returns: Whether anything was written.
    @discardableResult static func refresh(
        _ hike: Hike,
        transport: any CommunityTransporting,
        save: (ModelContext) throws -> Void = { try $0.save() }
    ) async -> Bool {
        await CommunityUploadCheck.refreshUploadResult(
            of: hike,
            submission: \.communityPhotoSubmissionID,
            result: \.communityPhotoContributionID,
            asking: { try await transport.contribution(of: $0) },
            reportingFailureAs: .init(
                couldNotAsk: "Could not check whether contributed photos are published",
                couldNotRecord: "Saw contributed photos go live but could not record it locally"
            ),
            save: save
        )
    }
}
