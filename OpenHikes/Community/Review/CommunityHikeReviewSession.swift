//
//  CommunityHikeReviewSession.swift
//  OpenHikes
//
//  One review of a queued hike, held where a turn of the phone cannot reach
//  it.
//
//  The review is drawn in the sheet in portrait and in the side panel in
//  landscape, so a turn builds it again in the other host. While what it held
//  was its own `@State`, the screen built there started the review over
//  (#1353): it downloaded the submission again, put back every photograph the
//  reviewer had struck off, set the title back to the one that was sent and
//  forgot a publish or a decline already under way. ``SheetPresentation``
//  keeps one of these for each queued hike on the stack, as it keeps a shared
//  hike's ``CommunityPreviewSession``, and ends it when the route leaves the
//  path — see ``CommunityReviewDecisions/end()``.
//
//  The contributed-photo review keeps a ``CommunityReviewDecisions`` and
//  nothing else, because the title is the one correction only a hike can
//  take — see ``CommunityReviewView``'s header.
//

import Observation

@Observable
final class CommunityHikeReviewSession {
    /// Non-isolated so releasing the last reference never requires proving
    /// we're on the main actor — see ``LocationManager``'s deinit for why.
    nonisolated deinit { /* intentionally empty */ }

    /// What has arrived, what is struck off and the decision under way.
    let decisions: CommunityReviewDecisions<CommunityHikeDetail>
    /// The title as it will be published, which starts as the one that was
    /// sent.
    ///
    /// Only ever the *listing's* title. The submission keeps what its author
    /// wrote — see ``CommunityReviewView``'s header for why that is both
    /// possible and deliberate.
    var titleDraft: String

    init(pending: CommunityPendingSubmission) {
        decisions = CommunityReviewDecisions(listing: pending.prospectiveListing)
        titleDraft = pending.title
    }
}
