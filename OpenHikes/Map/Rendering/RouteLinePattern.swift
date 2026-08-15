//
//  RouteLinePattern.swift
//  OpenHikes
//
//  How a finished route's line is drawn: whether the stroke is unbroken,
//  dashed or dotted, and whether direction chevrons ride along it. Chosen per
//  hike alongside the tint and the width.
//
//  The dash lengths and the chevron geometry live here rather than in the
//  renderer because two surfaces draw them: `DirectionalPolylineRenderer` on
//  the map, and the picker's swatches in the detail view. One source means the
//  swatch is a preview of the route rather than a drawing that resembles it.
//
//  A live recording is deliberately not covered by this: its trace is always
//  the same red dashed line, so "what am I recording right now" never depends
//  on a per-hike appearance choice.
//

import CoreGraphics
import Foundation

nonisolated enum RouteLinePattern: String, CaseIterable, Identifiable, Sendable {
    /// Chevrons alone, with no line behind them. They're drawn in the route's
    /// own tint here (the other patterns contrast them against the line), since
    /// they *are* the route.
    case arrowheads = "arrowheads"
    /// Long strokes with gaps between them.
    case dashed = "dashed"
    /// An unbroken line with chevrons pointing the way the route was walked.
    /// What every route was drawn as before this was a choice, and so still
    /// the default.
    case directional = "directional"
    /// Round dots — a dash pattern whose strokes are shorter than the line is
    /// wide, drawn with round caps.
    case dotted = "dotted"
    /// An unbroken line and nothing else.
    case solid = "solid"

    /// The appearance a hike gets when nothing has been chosen — including
    /// every hike that existed before the choice did.
    static let `default`: RouteLinePattern = .directional

    /// The order the picker shows them in: plainest first, then the two ways
    /// of breaking the line, then the one that drops it. `allCases` is sorted
    /// alphabetically, which is not an order anyone would choose to read.
    static let displayOrder: [Self] = [
        .solid, .directional, .dashed, .dotted, .arrowheads,
    ]

    var id: String { rawValue }

    /// Resolves a persisted id. An unrecognised one — a store written by a
    /// newer build, or a corrupted row — falls back to the default rather than
    /// leaving the route undrawable.
    init(storedID: String) {
        self = Self(rawValue: storedID) ?? .default
    }

    var title: String {
        switch self {
        case .solid: "Solid"
        case .directional: "Arrows"
        case .dashed: "Dashed"
        case .dotted: "Dotted"
        case .arrowheads: "Arrows only"
        }
    }

    /// Whether the stroke itself is drawn. False for ``arrowheads``, which is
    /// the whole difference between it and ``directional``.
    var drawsLine: Bool { self != .arrowheads }

    var drawsChevrons: Bool { self == .directional || self == .arrowheads }

    /// Chevrons drawn in the route's own colour rather than in a shade chosen
    /// to contrast with it: with no line underneath, a contrasting chevron
    /// would mean the route is no longer drawn in the colour that was picked.
    var chevronsUseRouteTint: Bool { self == .arrowheads }

    /// Dash lengths in screen points — stroke, gap — for a line of `width`.
    /// Empty for an unbroken stroke.
    ///
    /// Both derive from the width so a 12 pt line doesn't close its own gaps:
    /// round caps extend each stroke by half the line width at either end, and
    /// a fixed gap disappears entirely once the line is thick enough.
    func dashLengths(forWidth width: Double) -> [Double] {
        let lineWidth = max(width, Self.minimumLineWidth)
        switch self {
        case .solid, .directional, .arrowheads: return []
        case .dashed:
            return [
                max(lineWidth * Self.dashLengthMultiplier, Self.minimumDashLength),
                max(lineWidth * Self.dashGapMultiplier, Self.minimumDashGap),
            ]
        case .dotted:
            // Near-zero strokes: with a round cap each one draws as a dot one
            // line-width across, so the gap has to clear that width to read.
            return [
                Self.dotLength,
                max(lineWidth * Self.dotGapMultiplier, Self.minimumDashGap),
            ]
        }
    }

    /// Butt caps on a dashed line (round ones would grow every stroke by half
    /// the line width at each end and eat the gaps); round everywhere else,
    /// which is what turns a dotted pattern's near-zero strokes into dots.
    var lineCap: CGLineCap {
        self == .dashed ? .butt : .round
    }

    /// Chevron placement and size in screen points for a line of `width`, or
    /// `nil` when the pattern carries no chevrons.
    ///
    /// Screen points, not map points: chevrons stay the same size on screen at
    /// every zoom level, so the caller drawing into map space is the one that
    /// divides by the zoom scale.
    func chevronMetrics(forWidth width: Double) -> RouteChevronMetrics? {
        guard drawsChevrons else { return nil }
        let scale = self == .arrowheads ? Self.arrowheadScale : 1
        return RouteChevronMetrics(
            spacing: self == .arrowheads ? Self.arrowheadSpacing : Self.chevronSpacing,
            halfLength: max(Self.minimumChevronSize, width * Self.reachMultiplier) * scale,
            halfWidth: max(Self.minimumChevronSize, width * Self.spreadMultiplier) * scale,
            strokeWidth: max(Self.minimumChevronStroke, width * Self.strokeMultiplier) * scale
        )
    }

    // MARK: Geometry

    /// Gap between chevrons on a line, in screen points.
    private static let chevronSpacing: Double = 55
    /// Chevrons alone have to imply the path between them, so they sit closer
    /// together — and are drawn larger — than the ones riding a line.
    private static let arrowheadSpacing: Double = 38
    private static let arrowheadScale: Double = 1.7
    /// Chevron reach along the path, as a multiple of the line width.
    private static let reachMultiplier: Double = 1.1
    /// Chevron spread across the path, as a multiple of the line width.
    private static let spreadMultiplier: Double = 1.0
    private static let strokeMultiplier: Double = 0.55
    private static let minimumChevronSize: Double = 3
    private static let minimumChevronStroke: Double = 1.5
    private static let minimumLineWidth: Double = 1
    /// Dash and gap as multiples of the line width, so a wide line's gaps stay
    /// gaps. The gap clears the width itself on both broken patterns.
    private static let dashLengthMultiplier: Double = 3
    private static let dashGapMultiplier: Double = 2.5
    private static let dotGapMultiplier: Double = 2
    private static let minimumDashLength: Double = 6
    private static let minimumDashGap: Double = 4
    /// Not zero: a zero-length dash is not drawn at all on some paths, and a
    /// hairline is indistinguishable from a point once the cap rounds it.
    private static let dotLength: Double = 0.1
}

/// One chevron's placement and size, in screen points.
nonisolated struct RouteChevronMetrics: Equatable, Sendable {
    /// Distance between consecutive chevrons along the path.
    let spacing: Double
    /// Distance from a chevron's centre to its tip, along the path.
    let halfLength: Double
    /// Distance from a chevron's centre to each tail, across the path.
    let halfWidth: Double
    let strokeWidth: Double
}

/// The grey a chevron is drawn in when it rides a line: near-white on a dark
/// route, near-black on a light one, so it reads against the colour it sits on
/// whatever that colour is.
///
/// Shared by the map renderer and the picker's swatches — a swatch that
/// contrasted differently from the map would be advertising the wrong drawing.
nonisolated enum RouteChevronShade {
    /// Kept opaque so a chevron reads even on a translucent route.
    static let alpha: Double = 0.95

    static func luminance(red: Double, green: Double, blue: Double) -> Double {
        redWeight * red + greenWeight * green + blueWeight * blue
    }

    /// Grey level, 0…1, for a line of this luminance.
    static func gray(forLuminance luminance: Double) -> Double {
        luminance > darkThreshold ? darkShade : lightShade
    }

    private static let redWeight: Double = 0.299
    private static let greenWeight: Double = 0.587
    private static let blueWeight: Double = 0.114
    private static let darkThreshold: Double = 0.6
    private static let darkShade: Double = 0.15
    private static let lightShade: Double = 1.0
}
