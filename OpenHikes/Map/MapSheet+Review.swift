//
//  MapSheet+Review.swift
//  OpenHikes
//
//  The reviewer's two destinations: a queued submission — see
//  ``CommunityReviewView`` — and a queued set of contributed photographs —
//  see ``CommunityPhotoReviewView``.
//
//  These two are one subject — where a queue row goes — and they are
//  reachable only by somebody the *server* has decided is a reviewer, which is
//  almost nobody. Reading them beside the destinations every hiker reaches
//  obscured both. Their own file for the reason `MapSheet+Places.swift` is
//  one: the sheet's own file is at the length the linter allows, and these
//  are destinations rather than more of the sheet.
//

import SwiftUI

extension MapSheet {
    /// The review screen, or nothing.
    ///
    /// Guarded on the transport exactly as the community preview is, and
    /// unreachable without one for a second reason: the route that gets here
    /// comes from a queue that only a transport can fill.
    @ViewBuilder
    func pendingSubmissionDestination(
        _ pending: CommunityPendingSubmission
    ) -> some View {
        if let transport = appModel.communityTransport {
            CommunityReviewView(
                pending: pending,
                transport: transport,
                queue: appModel.communityReview,
                browser: appModel.community,
                // Back to the list the row was on. The row itself is already
                // gone — the screen tells the queue before it pops — so this
                // lands on a list that agrees with the decision just made.
                onFinished: { presentation.path.removeAll() }
            )
        }
    }

    /// The contributed-photo review screen, or nothing.
    ///
    /// Guarded on the transport for the reason the one above is, and
    /// unreachable without one for the same second reason: the route that
    /// gets here comes from a queue only a transport can fill.
    @ViewBuilder
    func pendingPhotosDestination(
        _ pending: CommunityPendingPhotos
    ) -> some View {
        if let transport = appModel.communityTransport {
            CommunityPhotoReviewView(
                pending: pending,
                transport: transport,
                queue: appModel.communityReview,
                browser: appModel.community,
                onFinished: { presentation.path.removeAll() }
            )
        }
    }
}
