//
//  TrailDraftMapSection.swift
//  OpenHikes
//
//  The maker's *On the Map* section, under *Follow Paths*: the hike detail's
//  card of the same name, in the maker's list. It holds what changes how the
//  map behind the sheet draws, rather than what the trail is.
//
//  **Color By** is the same control as Route Style's, bound to the same
//  setting, so *None* picked on an imported hike is *None* here too, and the
//  other way round. See ``RouteShading`` for why that setting is every hike's.
//
//  It is shown for a hiking line that has had colours to show — a graded
//  path, or heights read for it. Before that, and for the other travel modes,
//  there is nothing the control would change, and so no section. See
//  ``TrailDraftShading`` for why it stays once it has appeared rather than
//  following each answer.
//
//  *Hiking Routes* is not here: it is chosen on *Map Modes* alone — see
//  ``HikingRoutesPicker``.
//
//  Its own `View` for the reason ``TrailPlaceFilterSection`` is one: what it
//  reads stays out of ``TrailDraftView``'s body.
//

import OpenHikesData
import SwiftUI

struct TrailDraftMapSection: View {
    let maker: TrailDraftController

    var body: some View {
        if maker.draft.travelMode == .hiking, !maker.shading.offered.isEmpty {
            Section {
                RouteColoringPicker()
                    .accessibilityIdentifier("trail-draft-coloring")
            } header: {
                Text("On the Map")
            }
        }
    }
}
