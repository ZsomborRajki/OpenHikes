//
//  WalkShareCanvas.swift
//  OpenHikes
//
//  The share card itself: the photograph filling it, the stats box, the route
//  box, and the OpenHikes wordmark fixed along the bottom.
//
//  One canvas draws both the editor and the exported picture, so what is sent
//  is what was arranged. The editor hands it boxes and a photograph that take
//  gestures; the export hands it the same boxes standing still, and renders
//  the whole thing at the same point size with a larger pixel scale — which is
//  why every length here is a multiple of ``WalkShareMetrics/unit(for:)``
//  rather than a fixed number of points.
//
//  Nothing here is drawn with a material or Liquid Glass. `ImageRenderer`
//  draws neither, so a backing that looked frosted in the editor would arrive
//  as nothing in the picture; the boxes' backing is a plain translucent fill
//  for that reason, and looks the same in both.
//

import OpenHikesData
import SwiftUI

/// What a card is made of, fixed once the photograph is chosen.
///
/// A value the export can carry off the main actor: the photograph is an
/// already-decoded image, and everything else is figures and points.
nonisolated struct WalkShareCard: Sendable {
    let photo: PhotoImage
    let figures: WalkShareFigures
    let shape: WalkShareRouteShape
    /// The hike's tint, for ``WalkShareLineColor/trail``.
    let tint: Color
}

/// The card's one length: everything on it is a multiple of this, so the
/// same layout draws the same at any width.
nonisolated enum WalkShareMetrics {
    /// The width the boxes' natural sizes were designed at — an iPhone 18
    /// Pro's, in points.
    static let referenceWidth: CGFloat = 402

    static func unit(for canvas: CGSize) -> CGFloat {
        canvas.width / referenceWidth
    }

    /// How dark a box's ``WalkShareBoxStyle/card`` backing is.
    static let backingOpacity: CGFloat = 0.38
    /// How dark the shadow under anything drawn straight onto the photograph is.
    static let shadowOpacity: CGFloat = 0.55
}

struct WalkShareCanvas<Photo: View, Box: View>: View {
    let size: CGSize
    @ViewBuilder let photo: () -> Photo
    @ViewBuilder let box: (WalkShareWidget) -> Box

    var body: some View {
        ZStack(alignment: .topLeading) {
            photo()
            box(.route)
            box(.stats)
            WalkShareWordmark(unit: WalkShareMetrics.unit(for: size))
                .position(x: size.width / 2, y: size.height * (1 - WalkShareLayout.wordmarkBand / 2))
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }
}

/// The photograph, framed by `frame`.
struct WalkSharePhotoLayer: View {
    let photo: PhotoImage
    let frame: WalkSharePhotoFrame
    let size: CGSize

    var body: some View {
        let drawn = frame.drawnSize(of: photo.size, on: size)
        Image(photoImage: photo)
            .resizable()
            .frame(width: drawn.width, height: drawn.height)
            .position(
                x: size.width / 2 + frame.offset.dx * size.width,
                y: size.height / 2 + frame.offset.dy * size.height
            )
            .frame(width: size.width, height: size.height)
            .clipped()
            .accessibilityHidden(true)
    }
}

/// One box at its natural size times `scale`, unpositioned.
struct WalkShareBoxContent: View {
    let widget: WalkShareWidget
    let card: WalkShareCard
    let layout: WalkShareLayout
    /// ``WalkShareMetrics/unit(for:)`` times the box's own scale.
    let metric: CGFloat

    var body: some View {
        switch widget {
        case .stats:
            WalkShareStatsBox(figures: card.figures, shown: layout.shownStats, style: layout.statsStyle, metric: metric)
        case .route:
            WalkShareRouteBox(
                shape: card.shape,
                style: layout.routeStyle,
                color: layout.lineColor == .trail ? card.tint : .white,
                metric: metric
            )
        }
    }
}

/// A box where the layout put it — the export's box, which nothing moves.
struct WalkSharePlacedBox: View {
    let widget: WalkShareWidget
    let card: WalkShareCard
    let layout: WalkShareLayout
    let size: CGSize

    var body: some View {
        let placement = layout[widget]
        WalkShareBoxContent(
            widget: widget,
            card: card,
            layout: layout,
            metric: WalkShareMetrics.unit(for: size) * placement.scale
        )
        .position(x: placement.center.x * size.width, y: placement.center.y * size.height)
    }
}

// MARK: - The boxes

/// The backing both boxes share in their ``WalkShareBoxStyle/card`` style, and
/// the shadow that keeps them legible in ``WalkShareBoxStyle/bare``.
private struct WalkShareBacking: ViewModifier {
    let style: WalkShareBoxStyle
    let metric: CGFloat

    func body(content: Content) -> some View {
        switch style {
        case .card:
            content
                .padding(14 * metric)
                .background(.black.opacity(WalkShareMetrics.backingOpacity), in: .rect(cornerRadius: 20 * metric))
        case .bare:
            content
                .padding(6 * metric)
                .shadow(color: .black.opacity(WalkShareMetrics.shadowOpacity), radius: 4 * metric, y: 1 * metric)
        }
    }
}

/// The trail's name over a two-column grid of the chosen figures.
struct WalkShareStatsBox: View {
    let figures: WalkShareFigures
    let shown: [WalkShareStat]
    let style: WalkShareBoxStyle
    let metric: CGFloat

    private static let titleWidth: CGFloat = 240
    private static let columnSpacing: CGFloat = 22
    private static let labelTracking: CGFloat = 0.6
    private static let labelOpacity: CGFloat = 0.8
    private static let valueSize: CGFloat = 26

    var body: some View {
        // A figure with nothing true to say leaves the box rather than
        // printing a dash on somebody else's screen.
        let rows = shown.compactMap { stat in figures.value(of: stat).map { (stat, $0) } }
        VStack(alignment: .leading, spacing: 10 * metric) {
            Text(figures.title)
                .font(.system(size: 15 * metric, weight: .semibold))
                .lineLimit(1)
                .frame(maxWidth: Self.titleWidth * metric, alignment: .leading)
                .fixedSize()
            Grid(alignment: .leading, horizontalSpacing: Self.columnSpacing * metric, verticalSpacing: 10 * metric) {
                ForEach(Array(stride(from: 0, to: rows.count, by: 2)), id: \.self) { start in
                    GridRow {
                        ForEach(rows[start..<min(start + 2, rows.count)], id: \.0) { stat, value in
                            figure(stat, value)
                        }
                    }
                }
            }
        }
        .foregroundStyle(.white)
        .modifier(WalkShareBacking(style: style, metric: metric))
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Hike Figures")
        .accessibilityValue(rows.map { "\($0.0.label) \($0.1)" }.joined(separator: ", "))
    }

    private func figure(_ stat: WalkShareStat, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2 * metric) {
            Text(stat.label.uppercased())
                .font(.system(size: 10 * metric, weight: .semibold))
                .tracking(Self.labelTracking * metric)
                .opacity(Self.labelOpacity)
            Text(value)
                .font(.system(size: Self.valueSize * metric, weight: .bold, design: .rounded))
                .monospacedDigit()
        }
        .lineLimit(1)
        .fixedSize()
    }
}

/// The trail's outline, faint, with the stretches the walk covered drawn
/// over it — or the whole outline drawn firm when there are none to draw,
/// which is a trail edited since the walk.
struct WalkShareRouteBox: View {
    let shape: WalkShareRouteShape
    let style: WalkShareBoxStyle
    let color: Color
    let metric: CGFloat

    /// The box's side at a scale of 1.
    static let naturalSide: CGFloat = 150
    private static let lineWidth: CGFloat = 4.5
    /// The outline under the walked stretches: thinner, and see-through.
    private static let outlineWidthShare: CGFloat = 0.6
    private static let outlineOpacity: CGFloat = 0.35
    /// The start dot's radius, and its dark ring, as shares of the line.
    private static let startDotShare: CGFloat = 1.1
    private static let startRingShare: CGFloat = 0.3
    private static let startRingOpacity: CGFloat = 0.4

    var body: some View {
        let side = Self.naturalSide * metric
        Canvas { context, size in
            draw(in: &context, size: size)
        }
        .frame(width: side, height: side)
        .modifier(WalkShareBacking(style: style, metric: metric))
        .accessibilityElement()
        .accessibilityLabel("Route")
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let line = Self.lineWidth * metric
        // Inset by the line's own width so a stroke along the edge of the
        // square is not cut in half.
        let inset = line * 2
        let box = CGRect(origin: .zero, size: size).insetBy(dx: inset, dy: inset)
        func path(_ points: [CGPoint]) -> Path {
            Path { path in
                path.addLines(points.map { CGPoint(x: box.minX + $0.x * box.width, y: box.minY + $0.y * box.height) })
            }
        }
        let round = StrokeStyle(lineWidth: line, lineCap: .round, lineJoin: .round)
        let walkedAnything = !shape.walked.isEmpty
        context.stroke(
            path(shape.trail),
            with: .color(color.opacity(walkedAnything ? Self.outlineOpacity : 1)),
            style: walkedAnything
                ? StrokeStyle(lineWidth: line * Self.outlineWidthShare, lineCap: .round, lineJoin: .round)
                : round
        )
        for stretch in shape.walked {
            context.stroke(path(stretch), with: .color(color), style: round)
        }
        if let start = shape.trail.first {
            let center = CGPoint(x: box.minX + start.x * box.width, y: box.minY + start.y * box.height)
            let radius = line * Self.startDotShare
            let dot = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            context.fill(Path(ellipseIn: dot), with: .color(color))
            context.stroke(
                Path(ellipseIn: dot),
                with: .color(.black.opacity(Self.startRingOpacity)),
                lineWidth: line * Self.startRingShare
            )
        }
    }
}

/// The fixed signature along the card's bottom edge.
struct WalkShareWordmark: View {
    let unit: CGFloat

    private static let opacity: CGFloat = 0.92

    var body: some View {
        Label("OpenHikes", systemImage: "figure.hiking")
            .font(.system(size: 15 * unit, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(Self.opacity))
            .shadow(color: .black.opacity(0.5), radius: 3 * unit, y: 1 * unit)
            .fixedSize()
            .accessibilityHidden(true)
    }
}
