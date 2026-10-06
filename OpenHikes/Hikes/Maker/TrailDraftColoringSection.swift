//
//  TrailDraftColoringSection.swift
//  OpenHikes
//
//  The *Color By* control in the maker, above *Search This Area*: the same
//  control as Route Style's, bound to the same setting, so *None* picked on
//  an imported hike is *None* here too, and the other way round. See
//  ``RouteShading`` for why that setting is every hike's.
//
//  Shown for a hiking line that has had colours to show — a graded path, or
//  heights read for it. Before that, and for the other travel modes, there is
//  nothing the control would change. See ``TrailDraftShading`` for why the
//  section stays once it has appeared rather than following each answer.
//
//  Without OpenHikes Pro the line has no heights, so *Elevation* is locked
//  here and a tap on it opens the paywall — the one screen that says what
//  the subscription is for — rather than turning the shared setting to a
//  colouring this drawing cannot have. See ``TrailDraftShading``.
//
//  Its own `View` for the reason ``TrailPlaceFilterSection`` is one: what it
//  reads stays out of ``TrailDraftView``'s body.
//

import OpenHikesData
import SwiftUI

struct TrailDraftColoringSection: View {
    let maker: TrailDraftController

    @Environment(OpenHikesModel.self) private var appModel
    @State private var showsPaywall = false

    var body: some View {
        if maker.draft.travelMode == .hiking, !maker.shading.offered.isEmpty {
            Section {
                RouteColoringPicker(
                    unlockElevation: maker.shading.isElevationUnlocked ? nil : { showsPaywall = true }
                )
            }
            .accessibilityIdentifier("trail-draft-coloring")
            .sheet(isPresented: $showsPaywall) {
                MapPaywallView(store: appModel.entitlement)
            }
        }
    }
}
