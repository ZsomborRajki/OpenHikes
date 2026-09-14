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
    /// Opens the paywall, or `nil` for a hiker who already has the
    /// subscription and has the *Manage Subscription* row instead.
    ///
    /// A closure rather than the store, so this section keeps the property its
    /// own header argues for: it reads no entitlement, no product and no key.
    /// The caller decides whether the row is worth drawing; nothing here can
    /// be switched off by a resource that failed to resolve.
    var showPro: (() -> Void)?

    /// The subscription, the privacy policy, the terms, the project, and which
    /// build this is — in the one settings section that is drawn
    /// unconditionally.
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
            // First, because it is the row this section exists to guarantee.
            //
            // `MapPaywallView` had exactly one entry point in the whole app —
            // a locked provider row in Map Tiles — and that row is disabled
            // whenever `Secrets.canLoadTiles` is false, which is every build
            // without the gitignored `OpenHikes/Secrets.plist`. A Release
            // archive cut without that file therefore shipped an app in which
            // OpenHikes Pro could not be bought at all, and in which **Restore
            // Purchases**, which lives on the same screen, was equally out of
            // reach: an existing subscriber reinstalling starts un-entitled,
            // and their route back was the row that build disables.
            //
            // App Review has to be able to find and buy a listed in-app
            // purchase. A subscription in App Store Connect with no reachable
            // buy screen is the shape of a 2.1 rejection, and the key that
            // decided it lives on one laptop.
            //
            // So the row is here, in the section that is drawn unconditionally
            // and reads nothing that can fail to resolve, for the same reason
            // the policy link is. `Scripts/check-release-secrets.py` covers
            // the other half — a keyless archive can now sell the
            // subscription, but still cannot draw the styles it sells.
            if let showPro {
                Button {
                    showPro()
                } label: {
                    Label("OpenHikes Pro", systemImage: "map.circle")
                }
                .accessibilityIdentifier("about-pro-link")
                .accessibilityHint("Opens the subscription screen, where purchases can also be restored.")
            }

            Link(destination: MapPurchaseLinks.privacyPolicy) {
                Label("Privacy Policy", systemImage: "hand.raised")
            }
            .accessibilityIdentifier("privacy-policy-link")

            // Beside the policy rather than behind the paywall, and for a
            // different reason than 5.1.1(i). These terms are what a hiker
            // agrees to by publishing a hike — what they may share, the
            // licence they grant, and how to have something taken down — and
            // publishing is free, so a hiker bound by them may never see the
            // one screen that links Apple's EULA. The share form links them
            // too, at the moment they matter; this is where somebody goes
            // looking for them afterwards.
            Link(destination: MapPurchaseLinks.termsAndConditions) {
                Label("Terms & Conditions", systemImage: "doc.text")
            }
            .accessibilityIdentifier("terms-link")

            Link(destination: URL(string: "https://github.com/ZsomborRajki/OpenHikes")!) {
                Label("Project on GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
            }
            .accessibilityIdentifier("project-github-link")

            // Directly under the link that asks people to report an issue,
            // because it is the first thing the bug report wants and the app
            // said it nowhere: `Bundle.main` was read for a version in exactly
            // one place and it was the tile requests' User-Agent.
            //
            // The diagnostics screen looks like it answers this and does not
            // — its "App version" row is `report.appVersion`, off a stored
            // MetricKit payload, so it says which build *crashed* and shows
            // nothing at all on a fresh install. This is the running one, in
            // the spelling that screen uses for a report, so the two read the
            // same way.
            //
            // It is worth a row now rather than later because #340 made a
            // version map to a commit: an archived build is tagged
            // `v<marketing>-<build>`, which is only useful to somebody who can
            // read those two numbers off a device.
            LabeledContent("Version", value: AppVersion.display)
                .accessibilityIdentifier("app-version-row")
        } header: {
            Text("About")
        } footer: {
            Text(
                "The policy and the terms open in your browser, and are the ones the App Store"
                + " listing links too. Share feedback, suggestions, or report an issue on GitHub"
                + " \u{2014} the version above says which build you're on."
            )
        }
    }
}
