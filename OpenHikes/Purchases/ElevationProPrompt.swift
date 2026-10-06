//
//  ElevationProPrompt.swift
//  OpenHikes
//
//  The elevation chart's place on a screen whose route has no heights that
//  OpenHikes Pro would bring: the empty chart card, saying so, as a button
//  that opens the paywall.
//
//  Only where the subscription really does fill the chart in — a route found
//  on OpenStreetMap, which carries no heights and is given Stadia's on open,
//  and a hike in the library with none, which a subscriber's copy is given
//  once and keeps (see ``HikeElevationFill``). ``MapPaywallView`` lists that
//  feature, and the two have to agree.
//
//  Drawn only once StoreKit has said *not entitled*. While it has not
//  answered, the card would be offering something a subscriber already has.
//

import OpenHikesData
import SwiftUI

struct ElevationProPrompt: View {
    let tint: Color
    let message: LocalizedStringKey
    /// Run when the subscription arrives while this is on screen, so the
    /// screen can go and get the heights the hiker has just paid for.
    var onUnlocked: () -> Void = { /* nothing to fetch */ }

    @Environment(OpenHikesModel.self) private var appModel
    @State private var showsPaywall = false

    var body: some View {
        let entitlement = appModel.entitlement
        // A container that is always there, so the change below is seen
        // even though the card it follows is gone by then.
        VStack {
            if entitlement.state == .notEntitled {
                Button {
                    showsPaywall = true
                } label: {
                    ElevationPlaceholderView(
                        tint: tint,
                        message: message,
                        action: "Get Elevation with OpenHikes Pro"
                    )
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens OpenHikes Pro.")
                .accessibilityIdentifier("elevation-pro-prompt")
            }
        }
        .onChange(of: entitlement.isEntitled) { _, isEntitled in
            if isEntitled { onUnlocked() }
        }
        .sheet(isPresented: $showsPaywall) {
            MapPaywallView(store: entitlement)
        }
    }
}
