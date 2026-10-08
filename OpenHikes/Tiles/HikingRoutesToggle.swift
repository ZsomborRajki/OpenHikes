//
//  HikingRoutesToggle.swift
//  OpenHikes
//
//  The *Hiking Routes* switch: Waymarked Trails' marked routes over whichever
//  map is chosen — see ``TileLayer``.
//
//  One view on two screens — Settings' *Map Tiles* and the trail maker's
//  *On the Map* section — bound to the one synced setting, so flipping it on
//  either is flipping it on both, and on the map behind the sheet.
//
//  Not on the hike detail's *On the Map* card, deliberately: every other row
//  there is that hike's, so a switch among them reads as this hike's, and it
//  is every map's on every device the setting syncs to. The maker earns one
//  because the marked routes are what a trail is drawn along.
//
//  Nothing at all where the build does not offer the layer — see
//  ``TileLayer/isOffered`` — so no screen can show the switch without the
//  gate. A section that holds nothing else asks the gate itself, so as not
//  to draw a heading over nothing.
//
//  Its own `View` so the setting is read here: a flip redraws this row, and
//  the screens it sits on read the setting themselves only where what they
//  show depends on it.
//

import SwiftUI

struct HikingRoutesToggle: View {
    @AppStorage(SettingsKey.showsHikingRoutes) private var showsHikingRoutes = SettingsDefault.showsHikingRoutes

    var body: some View {
        if TileLayer.isOffered {
            toggle
        }
    }

    private var toggle: some View {
        Toggle(isOn: $showsHikingRoutes) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Hiking Routes")
                    Text("Marked trails from Waymarked Trails, drawn over any map when zoomed in.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "signpost.right.and.left")
            }
        }
        .frame(minHeight: StatCardMetrics.rowMinimumHeight)
        .accessibilityIdentifier("hiking-routes-toggle")
    }
}
