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
//  The *Color By* control at the bottom is the odd one out: it is not this
//  hike's, it is every hike's — see ``RouteShading``. It sits here because
//  this is where a hiker looks when they want to know why their line is not
//  the colour they picked, and it says so under itself.
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
                    RouteColoringPicker()
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
    /// taken to zero. Every hike starts on opaque black — see
    /// ``RouteStyle/defaultBorder``.
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

/// The *Color By* control, and the key to the colours it draws.
///
/// Its own view so the control's position is read here and not by
/// ``RouteStyleView``: moving it redraws one row rather than the colour
/// wells beside it. The trail maker shows the same one, bound to the same
/// setting — see ``TrailDraftColoringSection``.
struct RouteColoringPicker: View {
    /// How faded the key is at *None*: still there to say what the other
    /// positions would do, but plainly not what the map is showing.
    private static let offKeyOpacity = 0.4

    /// What tapping a locked *Elevation* does, or `nil` when it is not locked.
    ///
    /// Locked in the trail maker without OpenHikes Pro, whose heights are
    /// what it would colour by — see ``TrailDraftShading``. A locked tap
    /// leaves the shared setting alone, and the control shows *Difficulty*
    /// while the setting is *Elevation*, because that is what the maker draws.
    var unlockElevation: (() -> Void)?

    @Environment(OpenHikesModel.self) private var appModel

    var body: some View {
        let shading = appModel.routeShading
        let isLocked = unlockElevation != nil
        let shown = shading.coloring.locking(elevation: isLocked)
        VStack(alignment: .leading, spacing: 8) {
            Label("Color By", systemImage: "mountain.2")
                .frame(minHeight: StatCardMetrics.rowMinimumHeight)
                .accessibilityHidden(true)
            Picker(
                "Color By",
                selection: Binding(
                    get: { shown },
                    set: { picked in
                        if picked == .elevation, let unlockElevation {
                            unlockElevation()
                        } else {
                            shading.setColoring(picked)
                        }
                    }
                )
            ) {
                Text("Difficulty").tag(RouteColoring.difficulty)
                if isLocked {
                    // A segment draws a title or an image, never both, so the
                    // lock is a character of the title.
                    Text("Elevation \u{1F512}")
                        .accessibilityLabel("Elevation, OpenHikes Pro")
                        .tag(RouteColoring.elevation)
                } else {
                    Text("Elevation").tag(RouteColoring.elevation)
                }
                Text("None").tag(RouteColoring.off)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("route-coloring-picker")
            RouteShadeKey(coloring: shown)
                .opacity(shown == .off ? Self.offKeyOpacity : 1)
            Group {
                caption(for: shown)
                if isLocked {
                    Text("Elevation colors for a trail you draw come with OpenHikes Pro.")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.bottom, 10)
    }

    private func caption(for coloring: RouteColoring) -> Text {
        switch coloring {
        case .difficulty:
            Text(
                """
                Colors each stretch of the line by its OpenStreetMap \
                difficulty grade, as in the Difficulty section. Ungraded \
                stretches keep the route color. Applies to every hike.
                """
            )
        case .elevation:
            Text(
                """
                Colors each stretch of the line by how steep it is, uphill \
                or down. Stretches without elevation data keep the route \
                color. Applies to every hike.
                """
            )
        case .off:
            Text("Every hike is drawn in its own route color.")
        }
    }
}

/// The six steps of the scale, easiest to hardest, as one bar.
///
/// A key rather than a legend: the grade names are the Difficulty section's
/// to read out, and six of them would be a second copy of it on a screen
/// about something else. By elevation, each step is labelled with the grade
/// it starts at instead, since those are short and are the whole meaning.
/// VoiceOver hears the ends of the scale.
private struct RouteShadeKey: View {
    let coloring: RouteColoring

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 2) {
                ForEach(RouteShade.scale, id: \.self) { shade in
                    Rectangle().fill(shade.color)
                }
            }
            .frame(height: TrailBreakdownMetrics.barHeight / 2)
            .clipShape(.capsule)
            if coloring == .elevation {
                HStack(spacing: 2) {
                    ForEach(RouteShade.scale, id: \.self) { shade in
                        Text(verbatim: Self.gradeLabel(for: shade))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            } else {
                HStack {
                    Text("Easier")
                    Spacer()
                    Text("Harder")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(coloring == .elevation ? "Steepness colors" : "Difficulty colors")
        .accessibilityValue(
            coloring == .elevation
                ? "From green for level ground to black for grades of 30 percent or more"
                : "From green for hiking to black for difficult alpine hiking"
        )
    }

    /// The grade a step starts at, as a percentage — a figure, so formatted
    /// for the locale rather than catalogued.
    private static func gradeLabel(for shade: RouteShade) -> String {
        (RouteSteepness.lowerBoundPercent(of: shade) / 100).formatted(.percent)
    }
}
