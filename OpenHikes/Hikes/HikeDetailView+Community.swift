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
//  The subject here is one button, the sentence it is allowed to say, and the
//  one question it has to answer before it opens anything: whether this
//  device's subscription is current. See ``Hike/communitySubmissionID`` for why
//  that sentence is "shared" and never "published", and
//  ``MapEntitlementState/publishTap`` for why an unresolved entitlement
//  disables the button rather than letting the tap through.
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
            let tap = entitlement.state.publishTap
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
                Image(systemName: hike.communitySubmissionID == nil
                    ? "person.2"
                    : "person.2.fill")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .minimumTapTarget()
            }
            .buttonStyle(.plain)
            // Says *shared*, never *published*: a submission waits for review
            // and this app cannot find out whether it passed. See
            // ``Hike/communitySubmissionID``.
            .accessibilityLabel(
                hike.communitySubmissionID == nil
                    ? "Share with the community"
                    : "Already shared with the community"
            )
            // The lock is invisible in a toolbar glyph, so the hint is the
            // only warning a tap opens a purchase screen rather than the
            // form — the same sentence the locked rows in Settings say, for
            // the same reason.
            .accessibilityHint(Self.shareButtonHint(tap))
            .accessibilityIdentifier("community-share-button")
            .opacity(tap == .wait ? Self.unresolvedEntitlementOpacity : 1)
            .disabled(hike.pointCount < 2 || tap == .wait)
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

    /// Spoken after the button, because a toolbar glyph has nowhere to carry
    /// the *Pro* badge the provider rows in Settings show.
    private static func shareButtonHint(_ tap: PaidFeatureTap) -> String {
        switch tap {
        case .allow: ""
        case .unlock: "Requires OpenHikes Pro. Opens the unlock screen."
        case .wait: "Checking your subscription."
        }
    }

    /// Matches the dimming Settings gives a paid row while StoreKit is still
    /// answering.
    private static let unresolvedEntitlementOpacity: Double = 0.55
}
