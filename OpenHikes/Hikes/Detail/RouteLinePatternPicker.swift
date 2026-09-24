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
//  the hike's tint, border and pattern, and a colour drag writes the first two
//  continuously.
//  Keeping the reads here means a drag repaints five small swatches rather
//  than the detail screen around them.
//

import OpenHikesData
import OpenHikesShared
import SwiftUI

struct RouteLinePatternPicker: View {
    let hike: Hike

    private static let tileCornerRadius: CGFloat = 10
    /// Under the 6pt gap between swatches, so the five stay distinct targets
    /// and their glass still blends where they meet.
    private static let glassSpacing: CGFloat = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // The caption names the chosen style as well as marking it, for
            // the same reason the width row states its number: a swatch is a
            // picture of a line, and two of the five differ only in how long
            // the strokes are. It is also the one cue that survives a route
            // tint too pale for its own selection border to read.
            HStack {
                Label("Line style", systemImage: "scribble.variable")
                Spacer()
                Text(hike.routeLinePattern.title)
                    .foregroundStyle(.secondary)
            }
            .font(.caption.weight(.medium))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Line style")
            .accessibilityValue(hike.routeLinePattern.title)
            // Declared as text, because that is what it is. `children:
            // .ignore` merges the pair into one node carrying no trait to say
            // so, and `performAccessibilityAudit`'s hit-region check measures
            // an untyped node as something a finger has to land on — so a
            // caption nothing taps failed the audit at the 14.9 pt a
            // `.caption` line is tall.
            //
            // The trait is the fix rather than the padding. Growing the row to
            // the 44 pt floor — what ``minimumTapTarget()`` does for the
            // offline-tiles caption, which shares its row with a Delete button
            // and is that tall anyway — would hand a finger-sized target to
            // something with nothing to activate, and push the swatches under
            // it down by 29 pt to do it.
            .accessibilityAddTraits(.isStaticText)
            .accessibilityIdentifier("route-pattern-caption")
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
        // Two of the five swatches differ only in how long their strokes are,
        // and the line they change is on a map behind this sheet. The body
        // already reads the pattern for the caption, so this registers nothing
        // new.
        .sensoryFeedback(
            HapticMoment.choiceChanged.feedback,
            trigger: hike.routeLinePattern
        )
    }

    private func swatchButton(for pattern: RouteLinePattern) -> some View {
        let swatchHeight: CGFloat = 26
        let isSelected = hike.routeLinePattern == pattern
        return Button {
            hike.routeLinePattern = pattern
        } label: {
            RouteLinePatternSwatch(pattern: pattern, tint: hike.tintOpaque, border: hike.routeBorder)
                .frame(height: swatchHeight)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                // The selection border goes *above* `.glassSurface` in the
                // modifier order, which puts it inside the glass — it is drawn
                // as content, and the glass is drawn behind it. Ordered the
                // other way it is a stroke over a `glassEffect` inside a
                // `GlassEffectContainer`, and the container's own render pass
                // takes it down to the weight of the hairline every unselected
                // swatch already carries: the 2 pt tinted border was there and
                // could not be told from no border at all.
                .overlay {
                    RoundedRectangle(cornerRadius: Self.tileCornerRadius)
                        .strokeBorder(
                            isSelected ? hike.tintOpaque : .clear,
                            lineWidth: 2
                        )
                }
                // Plain glass under every swatch, selected or not. Tinting the
                // selected one filled it with the route's own colour — the
                // exact colour the line inside it is drawn in — so the swatch
                // that was meant to show the choice became a solid rectangle
                // showing nothing, and the pattern was unreadable until some
                // other swatch was picked. Selection is the border and the
                // caption instead; both sit clear of the line.
                .glassSurface(
                    .regular.interactive(),
                    in: .rect(cornerRadius: Self.tileCornerRadius)
                )
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
/// rule for the chevrons, and the same ``RouteBorder`` round all of them.
///
/// Only the chevron *spacing* differs — a swatch is too short to show one at
/// the on-map interval, so it spaces them to fit and stays a preview of the
/// pattern rather than a screenshot of a particular zoom level.
struct RouteLinePatternSwatch: View {
    let pattern: RouteLinePattern
    let tint: Color
    /// Clear draws no border, as on the map.
    var border: Color = .clear
    /// Fixed rather than taken from the hike: the swatch is only ~26 pt tall,
    /// so a 12 pt route would fill it, and reading the width here would also
    /// repaint every swatch on every sample of a width drag.
    var lineWidth: Double = 4

    /// Chevrons across the swatch, evenly spaced with a half-gap at each end.
    private static let chevronCount = 3

    var body: some View {
        Canvas { context, size in
            draw(in: context, size: size)
        }
        .accessibilityHidden(true)
    }

    private func draw(in context: GraphicsContext, size: CGSize) {
        let midY = size.height / 2
        var line = Path()
        line.move(to: CGPoint(x: 0, y: midY))
        line.addLine(to: CGPoint(x: size.width, y: midY))
        let lineStyle = StrokeStyle(
            lineWidth: lineWidth,
            lineCap: pattern.lineCap,
            dash: pattern.dashLengths(forWidth: lineWidth).map { CGFloat($0) }
        )
        let metrics = pattern.chevronMetrics(forWidth: lineWidth)
        let chevrons = metrics.map { chevronPath(for: $0, width: size.width, midY: midY) }
        let borderWidth = RouteBorder.width(forLineWidth: lineWidth)

        // Underneath everything, as on the map: the line again, wider, with
        // the line cleared back out of it, and the chevrons again, widened,
        // so the outline is the silhouette of both.
        if pattern.drawsLine {
            let dashes = RouteBorder.dashes(
                outlining: pattern.dashLengths(forWidth: lineWidth),
                cap: pattern.lineCap,
                borderWidth: borderWidth
            )
            context.stroke(
                line,
                with: .color(border),
                style: StrokeStyle(
                    lineWidth: lineWidth + borderWidth * 2,
                    lineCap: pattern.lineCap,
                    lineJoin: .round,
                    dash: dashes.lengths.map { CGFloat($0) },
                    dashPhase: dashes.phase
                )
            )
            var knockout = context
            knockout.blendMode = .clear
            knockout.stroke(line, with: .color(.black), style: lineStyle)
        }
        if let metrics, let chevrons {
            context.stroke(
                chevrons,
                with: .color(border),
                style: Self.chevronStyle(width: metrics.strokeWidth + borderWidth * 2)
            )
        }

        if pattern.drawsLine {
            context.stroke(line, with: .color(tint), style: lineStyle)
        }
        if let metrics, let chevrons {
            context.stroke(chevrons, with: .color(chevronColor), style: Self.chevronStyle(width: metrics.strokeWidth))
        }
    }

    private static func chevronStyle(width: Double) -> StrokeStyle {
        StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
    }

    private func chevronPath(for metrics: RouteChevronMetrics, width: Double, midY: Double) -> Path {
        let step = width / Double(Self.chevronCount)
        var chevrons = Path()
        for index in 0..<Self.chevronCount {
            let x = step * (Double(index) + 0.5)
            chevrons.move(to: CGPoint(x: x - metrics.halfLength, y: midY - metrics.halfWidth))
            chevrons.addLine(to: CGPoint(x: x + metrics.halfLength, y: midY))
            chevrons.addLine(to: CGPoint(x: x - metrics.halfLength, y: midY + metrics.halfWidth))
        }
        return chevrons
    }

    private var chevronColor: Color {
        guard !pattern.chevronsUseRouteTint else { return tint }
        return Color(white: RouteChevronShade.gray(forLuminance: tint.luminance))
            .opacity(RouteChevronShade.alpha)
    }
}
