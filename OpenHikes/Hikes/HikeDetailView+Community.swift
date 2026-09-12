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
//  The subject here is one button and the three things it has to answer
//  before it opens anything: where this hike is on the trip from private to
//  published (``CommunityPublicationState``), whether this device's
//  subscription is current (``MapEntitlementState/publishTap``), and whether
//  there is a transport at all.
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
    /// That asymmetry is also why the GPX export stays free and this does not.
    /// Exporting a file costs OpenHikes nothing; a published hike costs the
    /// public database's storage and every later reader's download, and both
    /// are billed to the developer for as long as the hike stands — the same
    /// recurring cost the subscription already exists to cover for the
    /// commercial tile sources. So the button behind it is
    /// ``MapEntitlementState/publishTap``, and a hiker without the
    /// subscription gets the paywall rather than the form.
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
            let tap = entitlement.state.publishTap
            let isWaiting = publication == .awaitingReview
            Button {
                switch tap {
                case .allow: isSharingToCommunity = true
                case .unlock: isShowingCommunityPaywall = true
                // Unreachable while the button is disabled below, and kept so
                // the rule survives that `.disabled` ever being loosened. A
                // tap that silently did nothing is the dead end the locked
                // provider rows in Settings were fixed for.
                case .wait: break
                }
            } label: {
                Image(systemName: Self.shareButtonSymbol(publication))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .minimumTapTarget()
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Self.shareButtonLabel(publication))
            // The lock and the wait are both invisible in a toolbar glyph, so
            // the hint is the only place either can be explained — the same
            // sentence the locked rows in Settings say, for the same reason.
            .accessibilityHint(Self.shareButtonHint(publication, tap))
            .accessibilityIdentifier("community-share-button")
            .opacity(tap == .wait || isWaiting ? Self.inactiveOpacity : 1)
            .disabled(hike.pointCount < 2 || tap == .wait || isWaiting)
            // Asks once per appearance, and only for a hike that has been sent
            // and not yet seen live — see ``CommunityPublicationCheck``. Here
            // rather than on the detail view's body because this button is the
            // only thing that reads the answer.
            .task(id: hike.id) {
                await CommunityPublicationCheck.refresh(hike, transport: transport)
            }
            .sheet(isPresented: $isSharingToCommunity) {
                CommunityShareSheet(
                    hike: hike,
                    transport: transport,
                    entitlement: entitlement
                )
            }
            .sheet(isPresented: $isShowingCommunityPaywall) {
                MapPaywallView(store: entitlement)
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

    /// Spoken after the button, because a toolbar glyph has nowhere to carry
    /// the *Pro* badge the provider rows in Settings show.
    ///
    /// The wait outranks the lock. A hike already sent cannot be sent again
    /// whatever the subscription says, so offering the paywall to somebody
    /// who has nothing to buy their way into would be the wrong sentence.
    private static func shareButtonHint(
        _ publication: CommunityPublicationState,
        _ tap: PaidFeatureTap
    ) -> String {
        if publication == .awaitingReview {
            return "Sent. It appears for other hikers once a person has checked it."
        }
        switch tap {
        case .allow:
            return publication == .published
                ? "Sharing again adds a second copy. The published one stays as it is."
                : ""
        case .unlock: return "Requires OpenHikes Pro. Opens the unlock screen."
        case .wait: return "Checking your subscription."
        }
    }

    /// Matches the dimming Settings gives a paid row while StoreKit is still
    /// answering, and reused for a hike waiting on a reviewer: both are a
    /// control that is real but has nothing to do yet.
    private static let inactiveOpacity: Double = 0.55
}
