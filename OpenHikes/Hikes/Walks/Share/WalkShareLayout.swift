//
//  WalkShareLayout.swift
//  OpenHikes
//
//  Where the two boxes sit on a walk's share card, how big they are and what
//  they look like — and the rules that keep them on the card.
//
//  Positions are fractions of the card rather than points, so one layout
//  draws the same on the editor's screen, at the export's pixel size, and on
//  the next phone the hiker opens the card on. The layout is remembered
//  between cards (`SettingsKey.walkShareLayout`): a hiker who likes the stats
//  top-left wants them there on the next walk too.
//

import CoreGraphics
import Foundation

/// The two boxes the hiker can move.
nonisolated enum WalkShareWidget: String, CaseIterable, Codable, Sendable {
    case route = "route"
    case stats = "stats"
}

/// Where one box sits and how big it is.
nonisolated struct WalkShareWidgetPlacement: Codable, Equatable, Sendable {
    /// The box's centre, as a fraction of the card's width and height.
    var center: CGPoint
    /// 1 is the box's natural size.
    var scale: Double

    static let scaleRange: ClosedRange<Double> = 0.6...2.2
}

/// A box drawn on a dark, rounded backing, or straight onto the photograph.
nonisolated enum WalkShareBoxStyle: String, CaseIterable, Codable, Sendable {
    case bare = "bare"
    case card = "card"
}

/// The colour the route is drawn in.
nonisolated enum WalkShareLineColor: String, CaseIterable, Codable, Sendable {
    /// The hike's own tint, the colour it is drawn in on the map.
    case trail = "trail"
    case white = "white"
}

nonisolated struct WalkShareLayout: Codable, Equatable, Sendable {
    var stats: WalkShareWidgetPlacement
    var route: WalkShareWidgetPlacement
    var statsStyle: WalkShareBoxStyle
    var routeStyle: WalkShareBoxStyle
    var lineColor: WalkShareLineColor
    /// In the order the box prints them. Never empty, never past
    /// ``WalkShareStat/maximumShown`` — see ``toggling(_:)``.
    var shownStats: [WalkShareStat]

    /// Stats across the top of the picture, the route low on the right —
    /// the two places a photograph's subject is least often in.
    static let standard = Self(
        stats: WalkShareWidgetPlacement(center: standardStatsCenter, scale: 1),
        route: WalkShareWidgetPlacement(center: standardRouteCenter, scale: 1),
        statsStyle: .card,
        routeStyle: .bare,
        lineColor: .white,
        shownStats: WalkShareStat.defaultShown
    )

    private static let standardStatsCenter = CGPoint(x: 0.5, y: standardStatsY)
    /// Low enough that the editor's bar, which the card does not carry,
    /// does not sit over the box the hiker is meant to arrange.
    private static let standardStatsY: CGFloat = 0.27
    private static let standardRouteCenter = CGPoint(x: standardRouteX, y: standardRouteY)
    private static let standardRouteX: CGFloat = 0.7
    private static let standardRouteY: CGFloat = 0.72

    /// The strip along the bottom the OpenHikes wordmark keeps, as a fraction
    /// of the card's height. No box may cover it.
    static let wordmarkBand: CGFloat = 0.08

    /// How close to the card's middle, in points, a dragged box's centre has
    /// to come to be pulled onto it.
    static let snapDistance: CGFloat = 10

    subscript(widget: WalkShareWidget) -> WalkShareWidgetPlacement {
        get {
            switch widget {
            case .stats: stats
            case .route: route
            }
        }
        set {
            switch widget {
            case .stats: stats = newValue
            case .route: route = newValue
            }
        }
    }

    /// `stat` switched on or off. Switching on a fifth, or off the last, is
    /// refused rather than quietly dropping another: the menu disables both,
    /// and this is what makes that the rule rather than the menu's opinion.
    func toggling(_ stat: WalkShareStat) -> Self {
        var copy = self
        if let index = shownStats.firstIndex(of: stat) {
            guard shownStats.count > 1 else { return self }
            copy.shownStats.remove(at: index)
        } else {
            guard shownStats.count < WalkShareStat.maximumShown else { return self }
            // Kept in the menu's order rather than the order of the taps, so
            // the box reads the same way however it was built.
            copy.shownStats = WalkShareStat.menuOrder.filter { $0 == stat || shownStats.contains($0) }
        }
        return copy
    }

    /// The centre a box of `boxSize` points may have on a card of `canvas`
    /// points, nearest to `proposed`: wholly on the card, and clear of the
    /// wordmark's band. A box too big to fit is centred on the room there is.
    static func clampedCenter(_ proposed: CGPoint, boxSize: CGSize, canvas: CGSize) -> CGPoint {
        let usableHeight = canvas.height * (1 - wordmarkBand)
        func clamp(_ value: CGFloat, half: CGFloat, length: CGFloat) -> CGFloat {
            guard half * 2 < length else { return length / 2 }
            return min(max(value, half), length - half)
        }
        return CGPoint(
            x: clamp(proposed.x, half: boxSize.width / 2, length: canvas.width),
            y: clamp(proposed.y, half: boxSize.height / 2, length: usableHeight)
        )
    }

    /// `center` pulled onto the card's vertical middle when it is within
    /// ``snapDistance`` of it, and whether it was.
    static func snapped(_ center: CGPoint, canvas: CGSize) -> (center: CGPoint, isSnapped: Bool) {
        let middle = canvas.width / 2
        guard abs(center.x - middle) <= snapDistance else { return (center, false) }
        return (CGPoint(x: middle, y: center.y), true)
    }

    /// Where a box of `boxSize` points whose stored centre is `center` (a
    /// fraction of the card) is drawn after a drag of `translation`: on the
    /// card, clear of the wordmark, and on the middle line when it came close.
    ///
    /// The drag starts from where the box is *drawn* — the stored centre
    /// clamped at the box's size now — not from the stored centre itself,
    /// which a box that has grown since (a figure added, the card backing,
    /// another trail's longer name) may no longer be able to reach. Starting
    /// from there would leave the box stuck at the edge until the finger had
    /// covered the gap. At rest nothing snaps, so the editor draws exactly
    /// what ``WalkSharePlacedBox`` exports.
    static func target(
        center: CGPoint,
        translation: CGSize,
        boxSize: CGSize,
        canvas: CGSize
    ) -> (center: CGPoint, isSnapped: Bool) {
        let stored = CGPoint(x: center.x * canvas.width, y: center.y * canvas.height)
        let drawn = clampedCenter(stored, boxSize: boxSize, canvas: canvas)
        guard translation != .zero else { return (drawn, false) }
        let proposed = CGPoint(x: drawn.x + translation.width, y: drawn.y + translation.height)
        let snapped = snapped(proposed, canvas: canvas)
        return (clampedCenter(snapped.center, boxSize: boxSize, canvas: canvas), snapped.isSnapped)
    }
}

// MARK: - Arranged without a finger

/// One step of a box, or of the photograph, moved by an accessibility action
/// rather than dragged — VoiceOver has no finger to drag with.
nonisolated enum WalkShareStep: CaseIterable, Sendable {
    case down, left, right, up

    /// The way the step goes, in the card's coordinates, where y grows down.
    var direction: CGVector {
        switch self {
        case .up: CGVector(dx: 0, dy: -1)
        case .down: CGVector(dx: 0, dy: 1)
        case .left: CGVector(dx: -1, dy: 0)
        case .right: CGVector(dx: 1, dy: 0)
        }
    }
}

extension WalkShareLayout {
    /// How far one step carries a box, as a fraction of the card's shorter
    /// side: twenty steps across a phone held upright.
    static let stepFraction: CGFloat = 0.05
    /// How much one *Larger* or *Smaller* changes a box's scale, so that four
    /// of them cover most of ``WalkShareWidgetPlacement/scaleRange``.
    static let scaleStep: Double = 1.25

    /// Where a box of `boxSize` points whose stored centre is `center` (a
    /// fraction of the card) goes one `step` on. From where it is drawn, for
    /// the reason ``target(center:translation:boxSize:canvas:)`` drags from
    /// there, and stopped at the edge the way a drag is. Never snapped: a
    /// step smaller than the pull would leave the box stuck on the middle,
    /// and *Center* is the way there.
    static func stepped(
        center: CGPoint,
        _ step: WalkShareStep,
        boxSize: CGSize,
        canvas: CGSize
    ) -> CGPoint {
        let stored = CGPoint(x: center.x * canvas.width, y: center.y * canvas.height)
        let drawn = clampedCenter(stored, boxSize: boxSize, canvas: canvas)
        let distance = min(canvas.width, canvas.height) * stepFraction
        let moved = CGPoint(
            x: drawn.x + step.direction.dx * distance,
            y: drawn.y + step.direction.dy * distance
        )
        return clampedCenter(moved, boxSize: boxSize, canvas: canvas)
    }

    /// The same box put on the card's vertical middle — the line a drag
    /// snaps to — at the height it is drawn at.
    static func centered(center: CGPoint, boxSize: CGSize, canvas: CGSize) -> CGPoint {
        let stored = CGPoint(x: center.x * canvas.width, y: center.y * canvas.height)
        let drawn = clampedCenter(stored, boxSize: boxSize, canvas: canvas)
        return clampedCenter(CGPoint(x: canvas.width / 2, y: drawn.y), boxSize: boxSize, canvas: canvas)
    }

    /// Which ninth of the card a box drawn at `center` points is in, which is
    /// what VoiceOver reads back after a step: precise enough to arrange two
    /// boxes by, and a figure in points would mean nothing to a listener.
    static func region(of center: CGPoint, canvas: CGSize) -> WalkShareRegion {
        guard canvas.width > 0, canvas.height > 0 else { return .center }
        func third(_ value: CGFloat, of length: CGFloat) -> Int {
            min(max(Int(value / length * 3), 0), 2)
        }
        let usableHeight = canvas.height * (1 - wordmarkBand)
        let row = third(center.y, of: usableHeight)
        let column = third(center.x, of: canvas.width)
        return WalkShareRegion.grid[row][column]
    }
}

/// A ninth of the share card, as VoiceOver says where a box is.
nonisolated enum WalkShareRegion: CaseIterable, Sendable {
    case bottom, bottomLeft, bottomRight, center, left, right, top, topLeft, topRight

    /// Row by row, top first.
    static let grid: [[Self]] = [
        [.topLeft, .top, .topRight],
        [.left, .center, .right],
        [.bottomLeft, .bottom, .bottomRight],
    ]

    var spoken: String {
        switch self {
        case .topLeft: String(localized: "Top left")
        case .top: String(localized: "Top")
        case .topRight: String(localized: "Top right")
        case .left: String(localized: "Left")
        case .center: String(localized: "Center")
        case .right: String(localized: "Right")
        case .bottomLeft: String(localized: "Bottom left")
        case .bottom: String(localized: "Bottom")
        case .bottomRight: String(localized: "Bottom right")
        }
    }
}

// MARK: - Remembered between cards

extension WalkShareLayout {
    /// The layout the last card was shared with, or ``standard`` when there
    /// is none or it cannot be read — a layout is a convenience, and one that
    /// fails to decode is worth less than starting over.
    nonisolated static func remembered(in defaults: UserDefaults) -> Self {
        guard let data = defaults.data(forKey: SettingsKey.walkShareLayout),
              var layout = try? JSONDecoder().decode(Self.self, from: data)
        else { return .standard }
        // A hand-edited or future value is brought back inside the rules.
        if layout.shownStats.isEmpty { layout.shownStats = WalkShareStat.defaultShown }
        layout.shownStats = Array(layout.shownStats.prefix(WalkShareStat.maximumShown))
        for widget in WalkShareWidget.allCases {
            let range = WalkShareWidgetPlacement.scaleRange
            layout[widget].scale = min(max(layout[widget].scale, range.lowerBound), range.upperBound)
        }
        return layout
    }

    nonisolated func remember(in defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: SettingsKey.walkShareLayout)
    }
}
