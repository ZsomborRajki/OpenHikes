//
//  RouteStyleView.swift
//  OpenHikes
//
//  How a hike's line is drawn on the map — its colour, border, width and
//  pattern — on a screen of its own, pushed from the *Route Style* row of the
//  hike detail's *On the Map* card.
//
//  These used to close the detail screen itself: two colour tiles in the
//  action row, a slider and five swatches under the toggles, which made the
//  bottom of the place card a control panel for something most hikers set
//  once. Apple Maps keeps that kind of setting a push away, and so does this.
//  Pushed rather than presented, so the sheet keeps its detent and the line
//  being restyled stays on the map above it.
//
//  A colour drag writes the hike continuously, and every read of the four
//  properties is in this screen, so the drag repaints this and the map's line
//  and nothing else.
//
//  The *Difficulty Colors* switch at the bottom is the odd one out: it is not
//  this hike's, it is every hike's — see ``RouteDifficultyShading``. It sits
//  here because this is where a hiker looks when they want to know why their
//  line is not the colour they picked, and it says so under itself.
//

import OpenHikesData
import OpenHikesShared
import SwiftUI

struct RouteStyleView: View {
    let hike: Hike

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PlaceCardList(title: String(localized: "Colors")) {
                    colorRow
                    borderRow
                }
                PlaceCardList(title: String(localized: "Line")) {
                    widthRow
                    RouteLinePatternPicker(hike: hike)
                        .padding(.vertical, 10)
                }
                PlaceCardList(title: String(localized: "All Hikes")) {
                    RouteDifficultySwitch()
                }
            }
            .padding()
        }
        .softScrollEdgeEffect(for: .top)
        .navigationTitle("Route Style")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private var colorRow: some View {
        ColorPicker(selection: tintBinding, supportsOpacity: true) {
            Label("Line Color", systemImage: "paintpalette")
        }
        .frame(minHeight: StatCardMetrics.rowMinimumHeight)
        .accessibilityLabel("Route color")
    }

    /// The outline round the line, beside the colour it outlines. The same
    /// picker, so "no border" is what it is for the colour too: the opacity
    /// taken to zero — which is where every hike starts.
    private var borderRow: some View {
        ColorPicker(selection: borderBinding, supportsOpacity: true) {
            Label("Border", systemImage: "circle.dashed")
        }
        .frame(minHeight: StatCardMetrics.rowMinimumHeight)
        .accessibilityLabel("Route border")
        .accessibilityIdentifier("route-border-picker")
    }

    private var widthRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Label("Line width", systemImage: "lineweight")
                Spacer()
                Text("\(Int(hike.routeWidth)) pt")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            // The caption row is what the slider's own label and value say, so
            // it is not a stop of its own.
            .accessibilityHidden(true)
            Slider(value: widthBinding, in: 1...12, step: 1)
                .tint(hike.tintOpaque)
                .accessibilityLabel("Line width")
                .accessibilityValue("\(Int(hike.routeWidth)) points")
                .accessibilityIdentifier("route-width-slider")
        }
        .padding(.vertical, 10)
    }

    private var tintBinding: Binding<Color> {
        Binding(
            get: { hike.tint },
            set: { hike.tintHex = $0.hexRGBA }
        )
    }

    private var borderBinding: Binding<Color> {
        Binding(
            get: { hike.routeBorder },
            set: { hike.routeBorderHex = RouteBorder.pickedHex($0.hexRGBA, over: hike.routeBorderHex) }
        )
    }

    private var widthBinding: Binding<Double> {
        Binding(
            get: { hike.routeWidth },
            set: { hike.routeWidth = $0 }
        )
    }
}

/// The *Route Style* row: what the line looks like now, and the way to the
/// screen that changes it.
///
/// Its own view so the preview's reads of the hike's colour, border and width
/// invalidate this row rather than ``HikeDetailView``.
struct RouteStyleRow: View {
    let hike: Hike

    var body: some View {
        NavigationLink(value: SheetRoute.routeStyle(hike)) {
            HStack(spacing: 12) {
                Label("Route Style", systemImage: "paintbrush.pointed")
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                RouteLinePatternSwatch(
                    pattern: hike.routeLinePattern,
                    tint: hike.tintOpaque,
                    border: hike.routeBorder
                )
                .frame(width: 44, height: 16)
                .accessibilityHidden(true)
                Image(systemName: "chevron.forward")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: StatCardMetrics.rowMinimumHeight)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("route-style-row")
    }
}

/// The *Difficulty Colors* switch, and the key to the colours it draws.
///
/// Its own view so the switch's position is read here and not by
/// ``RouteStyleView``: flipping it redraws one row rather than the colour
/// wells beside it.
private struct RouteDifficultySwitch: View {
    /// How faded the key is while the switch is off: still there to say what
    /// turning it on would do, but plainly not what the map is showing.
    private static let offKeyOpacity = 0.4

    @Environment(OpenHikesModel.self) private var appModel

    var body: some View {
        let shading = appModel.routeDifficulty
        VStack(alignment: .leading, spacing: 8) {
            Toggle(
                isOn: Binding(get: { shading.isEnabled }, set: { shading.setEnabled($0) })
            ) {
                Label("Difficulty Colors", systemImage: "mountain.2")
            }
            .frame(minHeight: StatCardMetrics.rowMinimumHeight)
            .accessibilityIdentifier("route-difficulty-toggle")
            TrailDifficultyKey()
                .opacity(shading.isEnabled ? 1 : Self.offKeyOpacity)
            Text(
                """
                Colors each stretch of the line by its OpenStreetMap \
                difficulty grade, as in the Difficulty section. Ungraded \
                stretches keep the route color. Applies to every hike.
                """
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.bottom, 10)
    }
}

/// The six grades' colours, easiest to hardest, as one bar.
///
/// A key rather than a legend: the names are the Difficulty section's to
/// read out, and six of them would be a second copy of it on a screen about
/// something else. VoiceOver hears the ends of the scale instead.
private struct TrailDifficultyKey: View {
    private static let grades = TrailDifficulty.displayOrdering.filter(\.isSurveyed)

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 2) {
                ForEach(Self.grades, id: \.self) { grade in
                    Rectangle().fill(grade.color)
                }
            }
            .frame(height: TrailBreakdownMetrics.barHeight / 2)
            .clipShape(.capsule)
            HStack {
                Text("Easier")
                Spacer()
                Text("Harder")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Difficulty colors")
        .accessibilityValue("From green for hiking to dark red for difficult alpine hiking")
    }
}
