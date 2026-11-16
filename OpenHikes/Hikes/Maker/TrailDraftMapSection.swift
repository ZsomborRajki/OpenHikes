//
//  TrailDraftMapSection.swift
//  OpenHikes
//
//  The maker's *On the Map* section, under *Follow Paths*: the hike detail's
//  card of the same name, in the maker's list. It holds what changes how the
//  map behind the sheet draws, rather than what the trail is.
//
//  **Hiking Routes** is *Map Modes*' pair of pictures, the clean map and the
//  marked routes over it, bound to the same synced value — see
//  ``HikingRoutesPicker``. It is here because the marked routes are what a
//  hiker drawing a trail is most likely to want to draw along.
//
//  **Color By** is the same control as Route Style's, bound to the same
//  setting, so *None* picked on an imported hike is *None* here too, and the
//  other way round. See ``RouteShading`` for why that setting is every hike's.
//
//  It is shown for a hiking line that has had colours to show — a graded
//  path, or heights read for it. Before that, and for the other travel modes,
//  there is nothing the control would change. See ``TrailDraftShading`` for
//  why it stays once it has appeared rather than following each answer.
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

struct TrailDraftMapSection: View {
    let maker: TrailDraftController

    @Environment(OpenHikesModel.self) private var appModel
    @State private var showsPaywall = false

    var body: some View {
        let showsColoring = maker.draft.travelMode == .hiking && !maker.shading.offered.isEmpty
        Section {
            TrailDraftHikingRoutes()
                // The pair brings the margins it stands in on *Map Modes*,
                // at its sides and under its caption, so the row adds only
                // the one above the pictures.
                .listRowInsets(EdgeInsets(top: Self.picturesTopInset, leading: 0, bottom: 0, trailing: 0))
            if showsColoring {
                RouteColoringPicker(
                    unlockElevation: maker.shading.isElevationUnlocked ? nil : { showsPaywall = true }
                )
                .accessibilityIdentifier("trail-draft-coloring")
            }
        } header: {
            Text("On the Map")
        }
        .sheet(isPresented: $showsPaywall) {
            MapPaywallView(store: appModel.entitlement)
        }
        // A purchase made from the paywall above: the heights this line
        // was refused are asked for now, or *Elevation* would draw nothing.
        .onChange(of: maker.shading.isElevationUnlocked) { _, unlocked in
            if unlocked { maker.elevationDidUnlock() }
        }
    }

    /// Above the pictures, what the pair itself leaves under its caption.
    private static let picturesTopInset: CGFloat = 12
}

/// The pair of pictures, with the setting they choose.
///
/// Its own `View` so the setting is read here: a choice redraws this row,
/// and not the section it is in.
private struct TrailDraftHikingRoutes: View {
    @AppStorage(SettingsKey.showsHikingRoutes) private var showsHikingRoutes = SettingsDefault.showsHikingRoutes

    var body: some View {
        HikingRoutesPicker(showsHikingRoutes: $showsHikingRoutes, identifierPrefix: "trail-draft-")
    }
}
