//
//  MapSidePanel.swift
//  OpenHikes
//
//  The landscape half of the map's primary surface: the sheet's own contents,
//  drawn down the leading edge with the map beside them instead of underneath.
//
//  `.presentationDetents` are honoured only in a compact-width, *regular*-height
//  presentation. iPhone landscape is compact height, so the system ignores them
//  and presents the sheet full-screen — and because `OpenHikesView` keeps that
//  sheet up permanently and puts it back whenever it is dismissed, full-screen
//  there does not mean "a taller sheet" but "no map, and no way back to one".
//  A phone taken out of a pocket at a junction rotates on its own; a hiker who
//  cannot see the map is the whole cost of that.
//
//  So landscape gets a panel rather than a sheet. It is a plain overlay, not a
//  presentation: nothing about it is modal, the map keeps taking touches beside
//  it, and `MapSheet` is handed to it unchanged — the same view, the same
//  navigation stack, the same screens. What the two shapes disagree about is
//  carried by ``SheetLayout`` and by ``MapSidePanelLayout``, whose numbers the
//  map is told as well so its own controls stay clear of the panel rather than
//  behind it.
//

import SwiftUI

/// The panel's fixed geometry.
///
/// A type of its own because ``MapSidePanel`` is generic over its contents, so
/// it can carry no stored static of its own — and because the map has to spend
/// these numbers without naming whatever content type the panel was built with.
enum MapSidePanelLayout {
    /// Wide enough for a hike row's title, distance and badge — a shade under
    /// the 375 pt an iPhone SE gives the same rows in portrait — and narrow
    /// enough to leave the map the larger half on every iPhone this app runs
    /// on. Fixed rather than a fraction of the screen because the map is told
    /// the same number and a fraction would need the container's width in the
    /// root view's body to compute.
    static let width: CGFloat = 320

    /// The gap between the panel and the edges of the screen.
    static let margin: CGFloat = 12

    static let cornerRadius: CGFloat = 24

    /// How far the map's own controls have to be pushed off the leading edge
    /// to clear the panel. Handed to ``MapView``, which spends it as
    /// additional safe-area inset, so the credit line and the camera pill sit
    /// beside the panel rather than behind it.
    static var mapInset: CGFloat { width + margin * 2 }
}

struct MapSidePanel<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(width: MapSidePanelLayout.width)
            .frame(maxHeight: .infinity)
            // The sheet's background is clear glass over the map
            // (`presentationBackground` in `OpenHikesView`); this is the same
            // surface, shaped rather than edge-to-edge because a panel has all
            // four of its own edges.
            .background {
                #if os(visionOS)
                Color.clear
                #else
                Color.clear.glassEffect(
                    .clear,
                    in: .rect(cornerRadius: MapSidePanelLayout.cornerRadius)
                )
                #endif
            }
            .clipShape(.rect(cornerRadius: MapSidePanelLayout.cornerRadius))
            .padding(MapSidePanelLayout.margin)
            .accessibilityIdentifier("map-side-panel")
    }
}
