//
//  RouteLinePatternPicker.swift
//  OpenHikes
//
//  Picks the per-hike ``RouteLinePattern`` from swatches that draw the pattern
//  itself rather than standing for it with a symbol: the choice is a visual
//  one, so the control shows the line the map will draw, in the route's own
//  colour.
//
//  A view of its own for the reason the other appearance pieces are: it reads
//  the hike's tint and pattern, and a colour drag writes the tint continuously.
//  Keeping the reads here means a drag repaints five small swatches rather
//  than the detail screen around them.
//

import SwiftUI

struct RouteLinePatternPicker: View {
    let hike: Hike

    private static let tileCornerRadius: CGFloat = 10
    /// Under the 6pt gap between swatches, so the five stay distinct targets
    /// and their glass still blends where they meet.
    private static let glassSpacing: CGFloat = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Line style", systemImage: "scribble.variable")
                .font(.caption.weight(.medium))
            HStack(spacing: 6) {
                GlassStack(spacing: Self.glassSpacing) {
                    HStack(spacing: 6) {
                        ForEach(RouteLinePattern.displayOrder) { pattern in
                            swatchButton(for: pattern)
                        }
                    }
                }
            }
        }
    }

    private func swatchButton(for pattern: RouteLinePattern) -> some View {
        let swatchHeight: CGFloat = 26
        let isSelected = hike.routeLinePattern == pattern
        return Button {
            hike.routeLinePattern = pattern
        } label: {
            RouteLinePatternSwatch(pattern: pattern, tint: hike.tintOpaque)
                .frame(height: swatchHeight)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                // The selected swatch is tinted glass rather than plain glass
                // under a stroked border: the tint is the route's own colour,
                // so selection is carried by the surface as well as by the
                // outline that still marks it.
                .glassSurface(
                    isSelected
                        ? .regular.tint(hike.tintOpaque).interactive()
                        : .regular.interactive(),
                    in: .rect(cornerRadius: Self.tileCornerRadius)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: Self.tileCornerRadius)
                        .strokeBorder(
                            isSelected ? hike.tintOpaque : .clear,
                            lineWidth: 2
                        )
                }
        }
        .buttonStyle(.plain)
        // On the leaf the user actually taps: a container identifier would be
        // pushed down onto every swatch and leave them indistinguishable.
        .accessibilityIdentifier("route-pattern-\(pattern.rawValue)")
        .accessibilityLabel(pattern.title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// A short horizontal run of route drawn exactly as ``RouteLinePattern`` tells
/// the map to draw it: same dash lengths, same chevron geometry, same contrast
/// rule for the chevrons.
///
/// Only the chevron *spacing* differs — a swatch is too short to show one at
/// the on-map interval, so it spaces them to fit and stays a preview of the
/// pattern rather than a screenshot of a particular zoom level.
struct RouteLinePatternSwatch: View {
    let pattern: RouteLinePattern
    let tint: Color
    /// Fixed rather than taken from the hike: the swatch is only ~26 pt tall,
    /// so a 12 pt route would fill it, and reading the width here would also
    /// repaint every swatch on every sample of a width drag.
    var lineWidth: Double = 4

    /// Chevrons across the swatch, evenly spaced with a half-gap at each end.
    private static let chevronCount = 3

    var body: some View {
        Canvas { context, size in
            let midY = size.height / 2
            if pattern.drawsLine {
                var line = Path()
                line.move(to: CGPoint(x: 0, y: midY))
                line.addLine(to: CGPoint(x: size.width, y: midY))
                context.stroke(
                    line,
                    with: .color(tint),
                    style: StrokeStyle(
                        lineWidth: lineWidth,
                        lineCap: pattern.lineCap == .butt ? .butt : .round,
                        dash: pattern.dashLengths(forWidth: lineWidth).map { CGFloat($0) }
                    )
                )
            }

            guard let metrics = pattern.chevronMetrics(forWidth: lineWidth) else { return }
            let step = size.width / Double(Self.chevronCount)
            var chevrons = Path()
            for index in 0..<Self.chevronCount {
                let x = step * (Double(index) + 0.5)
                chevrons.move(to: CGPoint(x: x - metrics.halfLength, y: midY - metrics.halfWidth))
                chevrons.addLine(to: CGPoint(x: x + metrics.halfLength, y: midY))
                chevrons.addLine(to: CGPoint(x: x - metrics.halfLength, y: midY + metrics.halfWidth))
            }
            context.stroke(
                chevrons,
                with: .color(chevronColor),
                style: StrokeStyle(
                    lineWidth: metrics.strokeWidth,
                    lineCap: .round,
                    lineJoin: .round
                )
            )
        }
        .accessibilityHidden(true)
    }

    private var chevronColor: Color {
        guard !pattern.chevronsUseRouteTint else { return tint }
        return Color(white: RouteChevronShade.gray(forLuminance: tint.luminance))
            .opacity(RouteChevronShade.alpha)
    }
}
