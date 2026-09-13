//
//  HikeDetailView+Community.swift
//  OpenHikes
//
//  The community share control on the hike detail screen.
//
//  Split out for the reason the offline-storage helpers next door are: the
//  detail view is the largest screen in the app and the linter holds it to a
//  file length, so a subject that can stand on its own does.
//
//  The subject here is one button and the two things it has to answer before
//  it opens anything: where this hike is on the trip from private to published
//  (``CommunityPublicationState``), and whether there is a transport at all.
//
//  The button is not a single control with a badge on it. Its three states do
//  three different things, and the middle one does nothing at all — a hike
//  waiting for review has no action available, because this app cannot
//  withdraw a submission, amend one, or hurry anybody along. A disabled
//  button is the honest shape for that, and the alternative — leaving it live
//  so the tap opens a form that would send a *second* copy — is the duplicate
//  this state exists to prevent.
//

import SwiftUI

extension HikeDetailView {
    /// Offers this hike to the community, beside the GPX export.
    ///
    /// Two share buttons rather than one menu, because they are not two ways
    /// of doing the same thing: the GPX export hands a file to whatever the
    /// hiker chooses and OpenHikes never sees it again, while this publishes
    /// to a database other people read. Folding them into one control would
    /// make the second reachable by a gesture learned for the first, and the
    /// second is the one that cannot be taken back by the person who made it.
    ///
    /// Free, like the rest of the community feature. Publishing sat behind the
    /// subscription once, on the grounds that a published hike is storage and
    /// downloads the developer pays for; what that bought instead was a list
    /// most of the app's hikers could read and not add to, which is the one
    /// shape a shared list cannot recover from. Nothing about payment ever
    /// decided what reaches other people's screens — see ``CommunitySchema``,
    /// where a person reviewing every submission still does.
    ///
    /// Absent rather than disabled when this launch has no transport — a
    /// hosted test or UI automation, which must not write to a real shared
    /// database. A disabled button would be a promise the launch cannot keep.
    @ViewBuilder var communityShareButton: some View {
        if let transport = communityTransport {
            let publication = CommunityPublicationState(
                submissionID: hike.communitySubmissionID,
                listingID: hike.communityListingID
            )
            let isWaiting = publication == .awaitingReview
            Button {
                isSharingToCommunity = true
            } label: {
                Image(systemName: Self.shareButtonSymbol(publication))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .minimumTapTarget()
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Self.shareButtonLabel(publication))
            // The wait is invisible in a toolbar glyph, so the hint is the only
            // place it can be explained.
            .accessibilityHint(Self.shareButtonHint(publication))
            .accessibilityIdentifier("community-share-button")
            .opacity(isWaiting ? Self.inactiveOpacity : 1)
            .disabled(hike.pointCount < 2 || isWaiting)
            // Asks once per appearance, and only for a hike that has been sent
            // and not yet seen live — see ``CommunityPublicationCheck``. Here
            // rather than on the detail view's body because this button is the
            // only thing that reads the answer.
            .task(id: hike.id) {
                await CommunityPublicationCheck.refresh(hike, transport: transport)
            }
            .sheet(isPresented: $isSharingToCommunity) {
                CommunityShareSheet(hike: hike, transport: transport)
            }
        }
    }

    /// Three glyphs for three states, because a badge on one glyph would be
    /// unreadable at the size a toolbar draws this.
    private static func shareButtonSymbol(_ publication: CommunityPublicationState) -> String {
        switch publication {
        case .notShared: "person.2"
        case .awaitingReview: "hourglass"
        case .published: "person.2.fill"
        }
    }

    /// Says *waiting for review* and never *rejected*: the absence of a
    /// listing covers a reviewer who has not looked and one who declined, and
    /// this app cannot tell those apart. See ``Hike/communityListingID``.
    private static func shareButtonLabel(_ publication: CommunityPublicationState) -> String {
        switch publication {
        case .notShared: "Share with the community"
        case .awaitingReview: "Waiting for review"
        case .published: "Published to the community"
        }
    }

    /// Spoken after the button, for the two states where the glyph alone does
    /// not say what a tap will do.
    private static func shareButtonHint(_ publication: CommunityPublicationState) -> String {
        switch publication {
        case .notShared: ""
        case .awaitingReview: "Sent. It appears for other hikers once a person has checked it."
        case .published: "Sharing again adds a second copy. The published one stays as it is."
        }
    }

    /// The same dimming Settings gives a row that is real but has nothing to
    /// do yet, which is exactly what a hike waiting on a reviewer is.
    private static let inactiveOpacity: Double = 0.55
}
