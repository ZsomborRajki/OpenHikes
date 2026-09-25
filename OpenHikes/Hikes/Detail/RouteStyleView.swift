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
