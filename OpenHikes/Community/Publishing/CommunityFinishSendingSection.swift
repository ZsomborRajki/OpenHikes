//
//  CommunityFinishSendingSection.swift
//  OpenHikes
//
//  What a publishing form shows for an upload that the review queue has not
//  been told about.
//
//  A send is two writes — see ``CommunityQueueingFailure`` — and when only the
//  second fails the route and the photographs are already in the public
//  database with nobody on the way to look at them. The form cannot go back to
//  being a form: its fields were sent, and offering them again is how the first
//  copy was stranded. It cannot say *sent* either, because nothing will happen
//  to it. So it says what is true, and offers the one thing that is left,
//  which uploads nothing — ``CommunityPublisher/finishQueueing(_:transport:save:)``.
//
//  Both forms draw it, and only the wording differs: one is about a hike and
//  the other about photographs going onto somebody else's. It is body code
//  and is on `Scripts/coverage-exclusions.txt` for the reason
//  `CommunitySharePhotoViews.swift` gives; the decision about *when* a form is
//  in this state is ``CommunitySendPhase``, which is measured.
//

import OpenHikesShared
import SwiftUI

/// The sections a form is replaced by while its upload waits for a notice.
struct CommunityFinishSendingSection: View {
    /// The accessibility identifiers of the three leaves, which each form
    /// names for itself: the automation asserts the two screens separately.
    struct Identifiers {
        let outcome: String
        let failure: String
        let button: String
    }

    /// Where the form is. Read here rather than as two flags, so that a retry
    /// in flight and a failed one are the same view in a different state and
    /// not two views — the button the hiker is looking at does not move.
    let phase: CommunitySendPhase
    /// What was uploaded and what finishing does, in this form's own words.
    let detail: LocalizedStringKey
    let identifiers: Identifiers
    let finish: () -> Void

    /// Why the last attempt to finish did not, when this launch made one.
    ///
    /// Gone while a retry is in flight, so the red sentence about the attempt
    /// that failed is not left standing under a button that is trying again.
    private var failure: CommunityFailure? {
        guard case .awaitingQueue(let failure) = phase else { return nil }
        return failure
    }

    var body: some View {
        CommunityOutcomeSection(
            symbol: "exclamationmark.icloud",
            tint: AnyShapeStyle(.orange),
            headline: Text("Uploaded, not yet sent for review"),
            detail: Text(detail),
            identifier: identifiers.outcome,
            // Only an attempt that just failed is news. A form opened on an
            // upload an earlier launch left behind has nothing to announce.
            moment: failure == nil ? nil : HapticMoment.outcomeFailed
        )
        if let failure {
            CommunityFailureNotice(failure: failure, identifier: identifiers.failure)
        }
        Section {
            Button("Finish Sending", systemImage: "paperplane", action: finish)
                .disabled(phase.isSending)
                .accessibilityIdentifier(identifiers.button)
        }
        // The outcome section knocks once, when it first reaches the screen,
        // and a retry never takes it off: `.finishing` draws this same view.
        // So a retry that fails is announced here, on the way back from
        // `.finishing`, or the second failure would arrive in silence.
        .sensoryFeedback(trigger: phase) { old, new in
            guard old == .finishing, case .awaitingQueue(.some) = new else { return nil }
            return HapticMoment.outcomeFailed.feedback
        }
    }
}
