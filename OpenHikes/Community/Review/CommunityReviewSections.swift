//
//  CommunityReviewSections.swift
//  OpenHikes
//
//  The parts of a hike's review that read what the rest of the form does
//  not, each a view of its own.
//
//  The form's body used to read the title, for the line under the field and
//  for whether *Publish* may be pressed, and it held the field's focus — and
//  in the same pass it ordered the submission's places along its route, which
//  projects every place onto every leg of the line (#1367). So every
//  keystroke and every time the keyboard came or went did that again on the
//  main thread: forty places on a day's recording measured at over a hundred
//  and fifty milliseconds a pass in a Debug build.
//
//  Only a `View` is a boundary — see *Render isolation, in practice* in
//  `AGENTS.md` — so each of these reads its own: the submission section the
//  title and its focus, the decision section the title again for what
//  Publish may do, and the place section the rows
//  ``CommunityHikeReviewSession`` keeps. What the form reads itself changes
//  when a download lands and when a decision is made.
//

import Foundation
import OpenHikesData
import OpenHikesShared
import SwiftUI

/// The title and credit, which are what a listing is found and read by.
///
/// The title is a field rather than a label, and it is the only editable
/// thing on the review that is not a photograph — see
/// ``CommunityReviewView``'s header.
struct CommunityReviewSubmissionSection: View {
    let pending: CommunityPendingSubmission
    let review: CommunityHikeReviewSession

    /// Whether the title field has the keyboard.
    ///
    /// Written by the *Done* button above the keyboard and by nothing else —
    /// see the field for why that button is here rather than being a
    /// convenience. Here rather than on the form, because a screen's focus
    /// re-runs that screen whenever the keyboard comes or goes.
    @FocusState private var isEditingTitle: Bool

    /// Written out because ``isEditingTitle`` is private, which would make
    /// the memberwise initializer private too.
    init(pending: CommunityPendingSubmission, review: CommunityHikeReviewSession) {
        self.pending = pending
        self.review = review
    }

    var body: some View {
        Section {
            LabeledContent("Title") {
                TextField("Title", text: Bindable(review).titleDraft)
                    .multilineTextAlignment(.trailing)
                    .disabled(review.decisions.isDeciding)
                    .focused($isEditingTitle)
                    .submitLabel(.done)
                    // The hike's own title field used to carry the same
                    // *Done* and does not any more — a keyboard accessory that
                    // arrives and leaves with its field stops the app ever
                    // reporting itself idle, at 60 seconds a gesture, which is
                    // what issue #539 was. This one is safe for the reason
                    // that one was not, and it was measured rather than
                    // assumed: the field and the accessory are both always in
                    // this hierarchy, and
                    // `testAReviewerCanCorrectTheTitleBeforePublishing` runs
                    // clean at 20.5s on the simulator that took 677.9s over
                    // the rename.
                    //
                    // It stays because here it is the difference between
                    // reaching the decision and not. This screen is a `Form` in a sheet that rests
                    // at half height: the keyboard covers what is left of it,
                    // *Publish* and *Decline* are at the foot, and a `Form`
                    // builds its rows lazily — so a reviewer who has just
                    // corrected a name can be left with neither the room to
                    // scroll to the decision nor a row down there to scroll
                    // to. `CommunityReviewUITests` failed on both halves of
                    // that before this button existed.
                    .toolbar {
                        ToolbarItemGroup(placement: .keyboard) {
                            Spacer()
                            RoleButton(.confirm) { isEditingTitle = false }
                                .accessibilityIdentifier("keyboard-done")
                        }
                    }
                    .accessibilityIdentifier("review-title-field")
            }
            LabeledContent("Credit") {
                // An empty credit is ordinary rather than wrong — the field is
                // optional on the share form — so it says so rather than
                // leaving a blank the reviewer has to interpret.
                Text(pending.authorName.isEmpty ? String(localized: "None given") : pending.authorName)
                    .foregroundStyle(pending.authorName.isEmpty ? .secondary : .primary)
            }
            LabeledContent("Hiked") {
                Text(pending.hikeDate.formatted(date: .abbreviated, time: .omitted))
            }
            LabeledContent("Distance") {
                // The same measurement, width and usage ``CommunityHikeRow``
                // formats with, so the figure a reviewer approves reads
                // identically to the one the row will show.
                Text(
                    Measurement(value: pending.distanceMeters, unit: UnitLength.meters)
                        .formatted(.measurement(width: .abbreviated, usage: .road))
                )
            }
        } header: {
            Text("Submission")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Sent \(pending.noticedAt.formatted(date: .abbreviated, time: .shortened))")
                if review.publishedTitle != pending.title {
                    // What the hiker called it, kept in front of the reviewer
                    // rather than replaced by the edit. It is the thing being
                    // corrected, so it is the thing an edit has to be judged
                    // against — and a reviewer who has second thoughts should
                    // not have to leave the screen to recover it.
                    Text("Sent as “\(pending.title)”")
                        .accessibilityIdentifier("review-original-title")
                }
            }
        }
    }
}

/// Every place's name and note, which is text the author wrote and is shown
/// to everybody who opens the hike once it is published — so it is read here,
/// like the description, or it is the one published field nobody checked.
///
/// In the order the places are met along the route, which is what the
/// published hike will list them in. Finding that order projects every place
/// onto every leg of the line, so it is measured once for the review, through
/// ``CommunityHikeReviewSession/orderedPlaces(_:along:)``, and off the main
/// actor past ``HikePlaceRows``'s budget: a long submission lists its places
/// as they were marked for a moment, and then in order, with this section
/// alone drawn again when the answer lands.
struct CommunityReviewPlaceSection: View {
    let places: [TrailPlace]
    let route: [RouteCoordinate]
    let review: CommunityHikeReviewSession

    var body: some View {
        Section("Places") {
            ForEach(review.orderedPlaces(places, along: route)) { row in
                TrailPlaceRowView(row: row, noteLineLimit: nil)
            }
        }
        .accessibilityIdentifier("review-places")
    }
}

/// *Publish* and *Decline* for a hike, and what the footer says about them.
///
/// Its own view because whether *Publish* may be pressed turns on the title,
/// which changes with every keystroke. The decision itself stays on
/// ``CommunityReviewView``, which holds the transport, the queue and the way
/// back; this only reads whether it may be asked for.
struct CommunityHikeDecisionSection: View {
    let pending: CommunityPendingSubmission
    let review: CommunityHikeReviewSession
    let publish: () -> Void

    var body: some View {
        CommunityReviewDecisionSection(
            isDeciding: review.decisions.isDeciding,
            canPublish: review.canPublish(pending),
            publishIdentifier: "review-publish",
            declineIdentifier: "review-decline",
            publish: publish,
            decline: { review.decisions.isConfirmingDecline = true },
            footer: { footer }
        )
    }

    @ViewBuilder private var footer: some View {
        if pending.authorID.isEmpty {
            // Reachable only from a submission CloudKit did not stamp with
            // a creator, which should be impossible — the type grants
            // create to `_icloud` and nothing else. Saying so beats a
            // disabled button with no explanation.
            Text(
                """
                This submission has no creator recorded, so a published \
                listing would be invisible and nobody could block its \
                author. It cannot be published.
                """
            )
        } else if !review.decisions.hasLoaded {
            // The same rule the button is disabled by, said out loud —
            // see ``CommunityHikeReviewSession/canPublish(_:)``. Declining
            // stays available, because a submission that will not load is a
            // perfectly good reason to.
            Text("Publishing waits for the description and photographs to load.")
        } else if review.publishedTitle.isEmpty {
            // A reviewer mid-edit rather than a submission with a problem,
            // which is why it says what to do rather than what is wrong.
            Text("A hike needs a title. Put one back to publish this.")
        } else {
            Text("Publishing makes this visible to everybody, immediately.")
        }
    }
}
