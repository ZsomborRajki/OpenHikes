//
//  AboutSection.swift
//  OpenHikes
//
//  The settings section that links out: the privacy policy, and the project
//  the app is built in the open as.
//
//  Its own file for a different reason than ``CloudSyncSection`` and
//  ``BlockedWalkersSection`` have one — there is no live state here and
//  nothing that could rebuild ``SettingsView``. It is separate because the
//  policy link is a submission requirement rather than a setting, and the
//  reasoning for where it lives belongs beside it: the same argument
//  ``MapPurchaseLinks`` makes for keeping those URLs out of a view body.
//

import SwiftUI

struct AboutSection: View {
    /// The privacy policy and the project, in the one settings section that is
    /// drawn unconditionally.
    ///
    /// App Review 5.1.1(i) wants the policy linked *inside* the app as well as
    /// in App Store Connect, and until this row existed the only link to it was
    /// the purchase disclosure on ``MapPaywallView`` — the one screen that
    /// cannot be relied on to be reachable. It dismisses itself once the store
    /// reports the subscription, so a subscriber has no route back to it; the
    /// provider rows that open it are disabled outright in a build whose paid
    /// sources have no API key; and while StoreKit is still answering, a paid
    /// row is disabled too. The policy has to survive all three, so nothing
    /// here reads an entitlement, a product or a key. The disclosure link stays
    /// where it is as well: 3.1.2(a) wants it on the screen that takes the
    /// money, and this is not that screen.
    ///
    /// It is the same ``MapPurchaseLinks/privacyPolicy`` the paywall links, so
    /// the two cannot drift and the assertion that it resolves covers both.
    var body: some View {
        Section {
            Link(destination: MapPurchaseLinks.privacyPolicy) {
                Label("Privacy Policy", systemImage: "hand.raised")
            }
            .accessibilityIdentifier("privacy-policy-link")

            Link(destination: URL(string: "https://github.com/ZsomborRajki/OpenHikes")!) {
                Label("Project on GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
            }
            .accessibilityIdentifier("project-github-link")
        } header: {
            Text("About")
        } footer: {
            Text(
                "The privacy policy opens in your browser, and is the one the App Store listing"
                + " links too. Share feedback, suggestions, or report an issue on GitHub."
            )
        }
    }
}
