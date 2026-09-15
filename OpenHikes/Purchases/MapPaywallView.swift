//
//  MapPaywallView.swift
//  OpenHikes
//
//  The one screen that sells anything. Reached only from a locked row in
//  Settings, never presented on its own — a hiking app that opens on a price
//  is not the app this is trying to be.
//
//  It is honest about what the money is for, because the honest answer is also
//  the persuasive one: Stadia and Thunderforest charge OpenHikes per map view,
//  and OpenStreetMap's own tile servers are donated infrastructure this app
//  has no right to push a paying feature onto. The free map is not a crippled
//  version of the paid one; it is the one that costs nothing to serve.
//
//  **Everything listed here has to be something the subscription actually
//  unlocks, and everything it unlocks has to be listed here.** That is not a
//  style rule: it is what App Review checks a subscription screen against, and
//  the reason a feature gated anywhere else in the app adds a row to the list
//  below in the same change.
//
//  ## Why `SubscriptionStoreView` rather than a layout of our own
//
//  This screen used to build its own price row, buy button, trial wording and
//  disclosure. Every one of those was an English sentence assembled by hand —
//  `"Renews automatically at \(price) per \(period) until cancelled."` — with
//  the plural formed by appending an `s`, sitting next to a `displayPrice`
//  that was already localized and storefront-correct. A storefront serving
//  `1 299 Ft` read *"Renews automatically at 1 299 Ft per month"*, and this is
//  the one screen where that mismatch is visible to a reviewer rather than
//  only to a user, because it is the 3.1.2(a) text.
//
//  `SubscriptionStoreView` formats all four in the buyer's own language,
//  including plural rules that cannot be expressed by appending `s` in most
//  languages. It also answers introductory-offer *eligibility*, which was
//  hand-rolled through `isEligibleForIntroOffer`, and it can show promotional
//  and win-back offers this screen previously could not show at all.
//
//  What it does not take away is the copy, which is the load-bearing part: the
//  marketing-content closure takes arbitrary SwiftUI, so the header, the
//  feature list and *Keeps OpenStreetMap Free* are the same words they were.
//
//  ## What is still ours
//
//  ``MapEntitlementStore`` keeps owning the entitlement. `.subscriptionStatusTask`
//  is the declarative form of its `statusTask`, and is deliberately not adopted:
//  the store has to answer before any view exists, for the `.notEntitled`
//  seeding in *Remember only the negative entitlement answer*.
//
//  Restore is ours too, and that is a decision rather than an oversight.
//  Apple's own restore button reports success or failure; ``MapEntitlementStore/restore()``
//  distinguishes a restore that reached the App Store and was told this account
//  owns nothing from one that never got an answer — and those two want
//  opposite things said to a customer who may already be paying.
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
            "Bright, high-contrast trail cartography that stays readable in sunlight. It keeps "
                + "the tiles you've looked at; downloading a route ahead is Stadia only."
        ),
        (
            "arrow.down.circle.fill",
            "Offline Stadia Maps",
            "Save a route's map to your phone for a hike with no signal."
        ),
        (
            "heart.fill",
            "Keeps OpenStreetMap Free",
            "The paid maps are billed per view. Paying for those is what keeps the free "
                + "map on donated servers OpenHikes doesn't charge for."
        ),
    ]

    private static let headerGlyphSize: CGFloat = 44
    private static let featureGlyphWidth: CGFloat = 28
    private static let sectionSpacing: CGFloat = 24
    private static let featureSpacing: CGFloat = 18

    var body: some View {
        NavigationStack {
            SubscriptionStoreView(productIDs: [MapEntitlementStore.productID]) {
                marketingContent
            }
            // The picker is for a group with more than one tier to choose
            // between; there is one product here, so a button is the whole
            // decision — and it is Apple's button, carrying Apple's price,
            // period and trial wording in the buyer's own language.
            .subscriptionStoreControlStyle(.prominentPicker)
            // App Review 3.1.2(a) wants the terms and the privacy policy on
            // the screen that takes the money, and a missing link here is one
            // of the more common in-app-purchase rejections. These are the
            // same two URLs the hand-built disclosure linked — see
            // ``MapPurchaseLinks``.
            .subscriptionStorePolicyDestination(
                url: MapPurchaseLinks.termsOfUse,
                for: .termsOfService
            )
            .subscriptionStorePolicyDestination(
                url: MapPurchaseLinks.privacyPolicy,
                for: .privacyPolicy
            )
            .storeButton(.visible, for: .policies)
            // Ours rather than `.storeButton(.visible, for: .restorePurchases)`
            // — see this file's header for why the distinction matters.
            .storeButton(.hidden, for: .restorePurchases)
            .safeAreaInset(edge: .bottom) { restoreRow }
            // The product's own name, as App Store Connect and
            // `OpenHikes.storekit` spell it, rather than a description of
            // what it currently unlocks: a customer reads this beside a
            // charge on their account and the two have to match. The product
            // identifier is a separate string again and can never change —
            // see ``MapEntitlementStore/productID``.
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

    /// The argument, unchanged. `SubscriptionStoreView`'s marketing-content
    /// closure takes arbitrary SwiftUI, so nothing here had to be surrendered
    /// to adopt it — which was the objection this screen would otherwise have
    /// raised, and the right one.
    private var marketingContent: some View {
        VStack(alignment: .leading, spacing: Self.sectionSpacing) {
            header
            VStack(alignment: .leading, spacing: Self.featureSpacing) {
                ForEach(Self.features, id: \.title) { feature in
                    featureRow(feature)
                }
            }
        }
        .padding(20)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "map.circle.fill")
                .font(.system(size: Self.headerGlyphSize))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("Read the ground you walk on")
                .font(.title2.weight(.semibold))
            // Named rather than collapsed into "them", which is what this
            // used to say. Two styles are unlocked and exactly one of them may
            // be downloaded ahead of a walk: `TileProvider.stadiaOutdoors` sets
            // `supportsBulkDownload`, and Thunderforest does not, because their
            // licence reserves pre-caching for a plan this app is not on. A
            // header promising that Pro "saves them to your phone" sold the
            // wrong half of the subscription to anybody who bought it for
            // Thunderforest.
            Text(
                "OpenStreetMap stays free and stays the default. Pro adds two commercial "
                + "outdoor map styles built for trails, and Stadia Outdoors downloads a "
                + "whole route to your phone for a hike with no signal."
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

    /// Restore, and whatever a restore had to say. Both are ours — see this
    /// file's header.
    ///
    /// The unlock-everywhere line sits here because it is the sentence a
    /// customer looks for next to *Restore*, and because Apple's own layout
    /// has no place for it.
    private var restoreRow: some View {
        VStack(spacing: 6) {
            if let message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("paywall-message")
            }
            Button("Restore Purchases") {
                Task { await restore() }
            }
            .font(.subheadline)
            .disabled(!store.canRestore)
            .accessibilityIdentifier("paywall-restore-button")
            Text("Unlocks on every device signed in to your Apple Account.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .alert("Nothing to Restore", isPresented: $showNothingToRestore) {
            Button("OK", role: .cancel) { /* dismiss */ }
        } message: {
            Text(
                "No previous purchase was found for this Apple Account. If you bought Pro "
                + "with a different account, sign in to that one and try again."
            )
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
