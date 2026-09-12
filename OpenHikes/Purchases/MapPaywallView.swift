//
//  MapPaywallView.swift
//  OpenHikes
//
//  The one screen that sells anything. Reached only from a locked row in
//  Settings or from the community share button, never presented on its own —
//  a hiking app that opens on a price is not the app this is trying to be.
//
//  It is honest about what the money is for, because the honest answer is also
//  the persuasive one: Stadia and Thunderforest charge OpenHikes per map view,
//  publishing a hike puts a route and a dozen photographs in a public database
//  the developer pays to hold for as long as the hike stands, and
//  OpenStreetMap's own tile servers are donated infrastructure this app has no
//  right to push a paying feature onto. The free map is not a crippled version
//  of the paid one; it is the one that costs nothing to serve.
//
//  **Everything listed here has to be something the subscription actually
//  unlocks, and everything it unlocks has to be listed here.** That is not a
//  style rule: it is what App Review checks a subscription screen against, and
//  the reason a feature gated anywhere else in the app adds a row to the list
//  below in the same change.
//

import StoreKit
import SwiftUI

struct MapPaywallView: View {
    let store: MapEntitlementStore

    @State private var message: String?
    /// Raised only by ``MapEntitlementStore/RestoreOutcome/nothingToRestore``,
    /// which is the one outcome that has actually asked the App Store and been
    /// told this account owns nothing. Every other way a restore can end is a
    /// dismissal or an error, and neither may claim that.
    @State private var showNothingToRestore = false

    private static let features: [(icon: String, title: String, detail: String)] = [
        (
            "mountain.2.fill",
            "Stadia Outdoors",
            "Hillshading, contour lines and trail-focused styling, at high resolution."
        ),
        (
            "map.fill",
            "Thunderforest Outdoors",
            "Bright, high-contrast trail cartography that stays readable in sunlight."
        ),
        (
            "arrow.down.circle.fill",
            "Offline Stadia Maps",
            "Save a route's map to your phone for a walk with no signal."
        ),
        (
            "person.2.fill",
            "Share Your Hikes",
            "Publish a walk — its route, its photos and your name — for other hikers to "
                + "find. Browsing and saving other people's hikes stays free for everyone."
        ),
        (
            "heart.fill",
            "Keeps OpenStreetMap Free",
            "The paid maps are billed per view, and a published hike is storage and "
                + "downloads OpenHikes pays for as long as it stands. Paying for those is "
                + "what keeps the free map on donated servers OpenHikes doesn't charge for."
        ),
    ]

    private static let headerGlyphSize: CGFloat = 44
    private static let featureGlyphWidth: CGFloat = 28
    private static let sectionSpacing: CGFloat = 24
    private static let featureSpacing: CGFloat = 18

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Self.sectionSpacing) {
                    header
                    VStack(alignment: .leading, spacing: Self.featureSpacing) {
                        ForEach(Self.features, id: \.title) { feature in
                            featureRow(feature)
                        }
                    }
                    if let message {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("paywall-message")
                    }
                    actions
                    disclosure
                }
                .padding(20)
            }
            // "Pro" rather than "Pro Maps": the subscription stopped being
            // only about maps when publishing moved behind it, and a title
            // narrower than what the screen sells is the kind of thing App
            // Review reads as a misdescribed subscription. The product
            // identifier still says `.maps` and cannot ever change — see
            // ``MapEntitlementStore/productID`` — which is exactly why the
            // name a customer reads is kept separate from it.
            .navigationTitle("OpenHikes Pro")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    DismissButton("Close")
                }
            }
            .dismiss(when: store.isEntitled)
        }
        .accessibilityIdentifier("map-paywall")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "map.circle.fill")
                .font(.system(size: Self.headerGlyphSize))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("Read the ground, and add to it")
                .font(.title2.weight(.semibold))
            Text(
                "OpenStreetMap stays free and stays the default. Pro adds two commercial "
                + "outdoor map styles built for trails, and lets you publish your own "
                + "walks for other hikers to follow."
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func featureRow(
        _ feature: (icon: String, title: String, detail: String)
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: feature.icon)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: Self.featureGlyphWidth)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(feature.title).font(.body.weight(.medium))
                Text(feature.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(feature.title)
        .accessibilityValue(feature.detail)
    }

    @ViewBuilder private var actions: some View {
        VStack(spacing: 12) {
            Button {
                Task { await buy() }
            } label: {
                Group {
                    if store.isWorking {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(store.terms?.callToAction ?? "Unlock OpenHikes Pro")
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            // The store may still be loading, or unreachable. A tap that could
            // only fail is worse than a button that says "not yet" — the rule
            // and its reasoning live on ``MapEntitlementStore/canPurchase``.
            .disabled(!store.canPurchase)
            .accessibilityIdentifier("paywall-purchase-button")

            Button("Restore Purchases") {
                Task { await restore() }
            }
            .font(.subheadline)
            // Unlike the button above, this one survives a product that never
            // loaded: restoring does not need one.
            .disabled(!store.canRestore)
            .accessibilityIdentifier("paywall-restore-button")
        }
        .alert("Nothing to Restore", isPresented: $showNothingToRestore) {
            Button("OK", role: .cancel) { /* dismiss */ }
        } message: {
            Text(
                "No previous purchase was found for this Apple Account. If you bought Pro "
                + "with a different account, sign in to that one and try again."
            )
        }
    }

    /// Everything App Review 3.1.2(a) requires on the screen that takes the
    /// money: what it costs, how long a period lasts, that it renews by
    /// itself, and working links to the terms and the privacy policy. A
    /// missing link here is one of the more common in-app-purchase
    /// rejections, and none of it may be hidden behind a disclosure arrow.
    private var disclosure: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(
                store.terms?.disclosure
                ?? "A subscription that renews automatically until cancelled."
            )
            .accessibilityIdentifier("paywall-disclosure")
            Text("Unlocks on every device signed in to your Apple Account.")
            HStack(spacing: 6) {
                Link("Terms of Use", destination: MapPurchaseLinks.termsOfUse)
                    .accessibilityIdentifier("paywall-terms-link")
                Text(verbatim: "·")
                    .accessibilityHidden(true)
                Link("Privacy Policy", destination: MapPurchaseLinks.privacyPolicy)
                    .accessibilityIdentifier("paywall-privacy-link")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func buy() async {
        message = nil
        switch await store.purchase() {
        case .purchased, .cancelled:
            // `.purchased` dismisses through `onChange`; a cancel says nothing,
            // because the user already knows what they just did.
            break
        case .pending:
            message = "That purchase is waiting for approval. Pro unlocks as soon as it goes "
                + "through — you don't need to buy it again."
        case .failed(let reason):
            message = reason
        }
    }

    private func restore() async {
        message = nil
        switch await store.restore() {
        case .restored, .cancelled:
            // `.restored` closes the screen the same way a purchase does; a
            // cancel says nothing, because the user already knows what they
            // just did.
            break
        case .nothingToRestore:
            showNothingToRestore = true
        case .failed(let reason):
            // Deliberately not the alert above. The App Store was not reached,
            // so nothing is known about what this account owns — telling the
            // customer to sign in to another one would be a guess, and a
            // discouraging one to hand somebody who is already paying.
            message = "Restore couldn’t be completed. \(reason) Nothing has "
                + "changed — you can try again in a moment."
        }
    }
}

#Preview {
    MapPaywallView(store: MapEntitlementStore(currentEntitlements: { false }))
}
