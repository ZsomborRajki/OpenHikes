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

import StoreKit
import SwiftUI

struct MapPaywallView: View {
    @Environment(\.dismiss)
    private var dismiss

    let store: MapEntitlementStore

    @State private var message: String?
    @State private var showRestoreFailed = false

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
            "heart.fill",
            "Keeps OpenStreetMap Free",
            "These sources are billed per map view. Paying for them is what keeps the "
                + "free map on donated servers that OpenHikes doesn't have to charge for."
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
            .navigationTitle("OpenHikes Pro Maps")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .onChange(of: store.isEntitled) { _, entitled in
                if entitled { dismiss() }
            }
        }
        .accessibilityIdentifier("map-paywall")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "map.circle.fill")
                .font(.system(size: Self.headerGlyphSize))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("Two more ways to read the ground")
                .font(.title2.weight(.semibold))
            Text(
                "OpenStreetMap stays free and stays the default. Pro adds two commercial "
                + "outdoor map styles built for trails."
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
                        Text(store.terms?.callToAction ?? "Unlock Pro Maps")
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            // The store may still be loading, or unreachable. A tap that could
            // only fail is worse than a button that says "not yet".
            .disabled(store.product == nil || store.isWorking)
            .accessibilityIdentifier("paywall-purchase-button")

            Button("Restore Purchases") {
                Task { await restore() }
            }
            .font(.subheadline)
            .disabled(store.isWorking)
            .accessibilityIdentifier("paywall-restore-button")
        }
        .alert("Nothing to Restore", isPresented: $showRestoreFailed) {
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
        if await store.restore() == false {
            showRestoreFailed = true
        }
    }
}

#Preview {
    MapPaywallView(store: MapEntitlementStore(currentEntitlements: { false }))
}
