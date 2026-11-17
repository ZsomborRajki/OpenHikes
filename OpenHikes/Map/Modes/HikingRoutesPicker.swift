//
//  HikingRoutesPicker.swift
//  OpenHikes
//
//  *Hiking Routes*: the switch as two pictures of the same ground, one clean
//  and one with the marked routes over it, so the choice shows what it does
//  before it is made. On *Map Modes* it sits under the map cards, because
//  the layer is drawn over whichever of them is chosen — see ``TileLayer``.
//
//  *Map Modes* is its only place, deliberately. Not on the hike detail's *On
//  the Map* card: every other row there is that hike's, so a choice among
//  them reads as this hike's, and it is every map's on every device the
//  setting syncs to. And no longer in the trail maker's *On the Map*
//  section, which drew the same pair, bound to the same setting: *Map
//  Modes* opens from the pill the location button stands in while the maker
//  is up, so it was the one choice offered twice.
//
//  The pictures are fixed, not drawn from the layer: a live one would need
//  the layer's squares for wherever the hiker is, and would show nothing
//  where no route is marked, which is where the choice most needs showing.
//  Both are the same square of the Bavarian Alps around Oberammergau,
//  OpenStreetMap's map with the layer over one of them, so *Map Modes*
//  credits OpenStreetMap for them whatever is chosen.
//
//  The caption names both of the layer's sources: OpenStreetMap, whose routes
//  these are, and Waymarked Trails, whose map style the lines and signs are
//  drawn to — see ``HikingRoutesStyle``. The line on the map credits only
//  whose data is drawn, so this is the one place the app says where the look
//  came from, and it stays while the look does.
//

import SwiftUI

struct HikingRoutesPicker: View {
    @Binding var showsHikingRoutes: Bool

    private static let cardSpacing: CGFloat = 24
    private static let horizontalMargin: CGFloat = 16

    var body: some View {
        VStack(spacing: 10) {
            // One above the other where the two side by side are wider than
            // the sheet, which an accessibility text size makes them: a row
            // that does not fit widens everything stacked with it, the ✕ and
            // the credits included, past the screen's edges.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: Self.cardSpacing) { options }
                VStack(spacing: Self.cardSpacing) { options }
            }

            Text("Marked trails from OpenStreetMap, drawn over any map in the style of Waymarked Trails.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Self.horizontalMargin)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 12)
    }

    @ViewBuilder private var options: some View {
        HikingRoutesOption(
            title: Text("Clean Map"),
            image: .mapModesCleanMap,
            isSelected: !showsHikingRoutes,
            identifier: "hiking-routes-off"
        ) { showsHikingRoutes = false }
        HikingRoutesOption(
            title: Text("Hiking Routes"),
            image: .mapModesHikingRoutes,
            isSelected: showsHikingRoutes,
            identifier: "hiking-routes-on"
        ) { showsHikingRoutes = true }
    }
}

/// One of the two: its picture, framed as a map card is, and its name.
private struct HikingRoutesOption: View {
    let title: Text
    let image: ImageResource
    let isSelected: Bool
    let identifier: String
    let action: () -> Void

    /// The map cards' side, so the two rows stand at one size.
    @ScaledMetric(relativeTo: .caption) private var side = MapModeThumbnailFrame.side

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
                    .frame(width: side, height: side)
                    .accessibilityHidden(true)
                    .modifier(MapModeThumbnailFrame(isSelected: isSelected))
                title
                    .font(.caption.weight(isSelected ? .semibold : .regular))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            .frame(width: MapModeThumbnailFrame.width(around: side))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier(identifier)
    }
}
