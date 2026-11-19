//
//  VectorTileArrows.swift
//  OpenHikes
//
//  The arrows along a one-way street or path, pointing the way it may be
//  travelled, as OpenStreetMap Carto draws them from zoom 16 (`roads.mss`,
//  its `directions`): along a street, Carto's marker in a darker shade of the
//  street's casing; along a path, a barbed arrow in a darker shade of the
//  path, with a halo.
//
//  The archive keeps a way's `oneway` tag as it is tagged, from zoom 14. An
//  arrow points along the line as drawn where it is `yes`, and against it
//  where it is `-1`; any other value has none, as in Carto. Carto also takes
//  a roundabout to be one-way, and the archive keeps no `junction`, so a
//  roundabout has arrows only where it is tagged `oneway` itself.
//
//  The archive merges a street's pieces into one line and keeps the way each
//  runs where it can. Where two pieces with the same tags meet head to head
//  it cannot, and one of them is drawn pointing back.
//
//  Carto spaces the two kinds of arrow differently, because Mapnik places a
//  marker and a line's text by different rules (``Arrow/Style``), and both
//  rules are kept: a short one-way street has no arrow, and a short one-way
//  path has one. Pieces of one kind of line that meet end to start are joined
//  first, keeping their direction. As with a name along a line, a tile draws
//  only the arrows whose marks lie inside it, and an arrow only where it lies
//  wholly inside the tile, clear of everything that claimed room before it —
//  the streets' names, which Carto places first — so no arrow is cut at a
//  tile's edge.
//

import CoreGraphics
import Foundation

nonisolated enum VectorTileArrows {
    /// Carto draws the arrows from this zoom.
    static let minimumZ = 16
    /// From one arrow to the next along a line, in the pixels of a 256-pixel
    /// tile: Carto's `marker-spacing` and `text-spacing`.
    static let spacing: CGFloat = 180

    /// What an arrow stands along: a kind of street or path, each with its
    /// arrow. Ordered by ``importance``.
    enum Kind: Sendable {
        case bridleway
        case cycleway
        /// Footways, paths and steps: every path not listed.
        case footway
        case livingStreet
        /// Residential, unclassified and service roads: every minor road.
        case minorRoad
        case motorway
        case pedestrian
        case primary
        case secondary
        /// Tertiary, and every other major road.
        case tertiary
        case track
        case trunk

        /// The more important first: the order their lines claim room in.
        static let importance: [Self] = [
            .motorway, .trunk, .primary, .secondary, .tertiary, .minorRoad, .livingStreet, .pedestrian,
            .footway, .cycleway, .track, .bridleway,
        ]

        /// The kind of a line in the `roads` layer, or `nil` for one Carto
        /// draws no arrows along: a railway, a ferry, a pier. Its `kind`
        /// and `kind_detail` first, then its `kind` alone.
        init?(kind: String?, detail: String?) {
            guard let kind, !VectorTileStyle.isPier(kind: kind, detail: detail),
                  let found = Self.keyed["\(kind)/\(detail ?? "")"] ?? Self.keyed["\(kind)/*"]
            else { return nil }
            self = found
        }

        /// Keyed `kind/kind_detail`, with `kind/*` for every detail not listed.
        private static let keyed: [String: Self] = [
            "highway/*": .motorway,
            "major_road/trunk": .trunk,
            "major_road/trunk_link": .trunk,
            "major_road/primary": .primary,
            "major_road/primary_link": .primary,
            "major_road/secondary": .secondary,
            "major_road/secondary_link": .secondary,
            "major_road/*": .tertiary,
            "minor_road/*": .minorRoad,
            "other/living_street": .livingStreet,
            "path/pedestrian": .pedestrian,
            "path/cycleway": .cycleway,
            "path/track": .track,
            "path/bridleway": .bridleway,
            "path/*": .footway,
        ]

        /// Carto's `-oneway-arrow-color`s: each the street's casing or the
        /// path's color, darkened.
        var arrow: Arrow {
            switch self {
            case .motorway: Arrow(.marker, "#741334")
            case .trunk: Arrow(.marker, "#612617")
            case .primary: Arrow(.marker, "#543800")
            case .secondary: Arrow(.marker, "#444C03")
            case .tertiary: Arrow(.marker, "#424242")
            case .minorRoad: Arrow(.marker, "#555555")
            case .livingStreet: Arrow(.marker, "#6E6E6E")
            case .pedestrian: Arrow(.marker, "#595959")
            case .footway: Arrow(.text, "#B31806")
            case .cycleway: Arrow(.text, "#000080")
            case .track: Arrow(.text, "#664400")
            case .bridleway: Arrow(.text, "#003400")
            }
        }
    }

    /// One arrow's look.
    struct Arrow: Sendable {
        let style: Style
        let color: CGColor

        /// How Carto draws an arrow, which is also how Mapnik places it.
        enum Style: Sendable {
            /// Along a street, `symbols/oneway.svg` as a marker: the first
            /// half a spacing from the line's start, then one every spacing,
            /// each sliding up to half a spacing to find room. A line shorter
            /// than half a spacing has none.
            case marker
            /// Along a path, the character 🠖 at 15 pixels as text: as many
            /// as fit a spacing apart, spread evenly over the line, each
            /// sliding up to half the interval between two. A line that the
            /// arrow fits on has one.
            case text
        }

        init(_ style: Style, _ hex: String) {
            self.style = style
            color = VectorTileStyle.color(hex)
        }

        /// The arrow's outline. The text's character is drawn as an outline
        /// of its size, because no font on the device need have it.
        var outline: Outline {
            switch style {
            case .marker: .marker
            case .text: .barb
            }
        }

        /// How far the halo reaches past the outline, in the pixels of a
        /// 256-pixel tile: Carto's `text-halo-radius`. A marker has none.
        var haloRadius: CGFloat {
            style == .text ? VectorTileArrows.textHaloRadius : 0
        }

        /// The room kept from everything placed before it: Carto's
        /// `text-margin`. A marker keeps none.
        var margin: CGFloat {
            style == .text ? VectorTileArrows.textMargin : 0
        }
    }

    /// An arrow's outline, pointing right, in the pixels of a 256-pixel tile.
    struct Outline: Sendable {
        let width: CGFloat
        let height: CGFloat
        let points: [CGPoint]

        /// `symbols/oneway.svg`: a shaft one pixel wide and a head 5 pixels
        /// across, 12 pixels long in all.
        static let marker = Self(width: 12, height: 5, points: [
            (0, 2), (7, 2), (7, 0), (12, 5 / 2), (7, 5), (7, 3), (0, 3),
        ])

        /// 🠖: a shaft one pixel wide under a head with its barbs swept back,
        /// 12 pixels long and 7 across.
        static let barb = Self(width: 12, height: 7, points: [
            (0, 3), (8, 3), (6, 0), (12, 7 / 2), (6, 7), (8, 4), (0, 4),
        ])

        private init(width: CGFloat, height: CGFloat, points: [(x: CGFloat, y: CGFloat)]) {
            self.width = width
            self.height = height
            self.points = points.map { CGPoint(x: $0.x, y: $0.y) }
        }

        /// The outline `unit` pixels for each of its own, centred on the
        /// origin.
        func path(unit: CGFloat) -> CGPath {
            let path = CGMutablePath()
            path.addLines(between: points.map { point in
                CGPoint(x: (point.x - width / 2) * unit, y: (point.y - height / 2) * unit)
            })
            path.closeSubpath()
            return path
        }
    }

    /// One or more of the archive's one-way lines, joined end to start, its
    /// points in the order the way is travelled, in the picture's pixels.
    struct OneWayLine: Equatable {
        let kind: Kind
        let points: [CGPoint]
    }

    static let textHaloRadius: CGFloat = 1.5
    static let textMargin: CGFloat = 2
    static let halo = VectorTileStyle.color("#FFFFFF99")
    /// Carto's `marker-max-error`: how far a marker may slide to find room,
    /// as a share of the spacing.
    static let markerSlide: CGFloat = 0.5

    // MARK: Choosing

    /// The one-way lines `tile` offers at `target`'s zoom, joined, each
    /// running the way it is travelled, the more important kind first.
    static func lines(
        in tile: MapboxVectorTile,
        source: VectorTileAddress,
        target: VectorTileAddress
    ) -> [OneWayLine] {
        guard target.z >= minimumZ, let layer = tile.layers["roads"] else { return [] }
        let geometry = VectorTileGeometry(extent: layer.extent, source: source, target: target)
        var pieces: [Kind: [[CGPoint]]] = [:]
        for feature in layer.features where feature.type == .line {
            guard let kind = Kind(kind: feature.string("kind"), detail: feature.string("kind_detail")) else { continue }
            switch feature.string("oneway") {
            case "yes": pieces[kind, default: []] += geometry.lines(of: feature)
            case "-1": pieces[kind, default: []] += geometry.lines(of: feature).map { $0.reversed() }
            default: continue
            }
        }
        return Kind.importance.flatMap { kind in
            joined(pieces[kind] ?? []).map { OneWayLine(kind: kind, points: $0) }
        }
    }

    /// `parts` joined wherever one ends where another begins, which brings
    /// back a street the archive split while keeping the way it runs. Two
    /// parts that meet head to head stay apart.
    static func joined(_ parts: [[CGPoint]]) -> [[CGPoint]] {
        var remaining = parts.filter { $0.count > 1 }
        var lines: [[CGPoint]] = []
        while var line = remaining.popLast() {
            while true {
                if let next = remaining.firstIndex(where: { meets(line.last, $0.first) }) {
                    line += remaining.remove(at: next).dropFirst()
                } else if let previous = remaining.firstIndex(where: { meets($0.last, line.first) }) {
                    line = remaining.remove(at: previous) + line.dropFirst()
                } else {
                    break
                }
            }
            lines.append(line)
        }
        return lines
    }

    // MARK: Placing

    /// Where along a line `length` long an arrow `width` long in `style` is
    /// tried, `spacing` apart as that style spaces them, each mark with the
    /// spots it may slide to `step` apart, nearest first, where the whole
    /// arrow lies on the line.
    static func marks(
        _ style: Arrow.Style,
        length: CGFloat,
        width: CGFloat,
        spacing: CGFloat,
        step: CGFloat
    ) -> [VectorTileLineLabels.Mark] {
        guard width <= length, spacing > 0, step > 0 else { return [] }
        let distances: [CGFloat]
        let reach: CGFloat
        switch style {
        case .marker:
            distances = Array(stride(from: spacing / 2, through: length, by: spacing))
            reach = spacing * markerSlide
        case .text:
            let count = max(Int((length / (spacing + width)).rounded(.down)), 1)
            let interval = length / CGFloat(count)
            distances = (0..<count).map { interval / 2 + CGFloat($0) * interval }
            reach = interval / 2
        }
        var slides: [CGFloat] = [0]
        for slide in stride(from: step, through: reach, by: step) {
            slides += [slide, -slide]
        }
        let fits = (width / 2)...(length - width / 2)
        return distances.compactMap { distance in
            let spots = slides.map { distance + $0 }.filter(fits.contains)
            return spots.isEmpty ? nil : VectorTileLineLabels.Mark(distance: distance, spots: spots)
        }
    }

    /// Where one arrow stands.
    struct Placement {
        let arrow: Arrow
        /// The arrow's middle, in the picture's pixels.
        let center: CGPoint
        /// The way it points, in radians from the picture's x axis.
        let angle: CGFloat
        /// The room it takes, halo included.
        let frame: CGRect

        /// The arrow `distance` along `path`, turned to the line between its
        /// tail and its head.
        init(arrow: Arrow, along path: MeasuredPath, at distance: CGFloat, unit: CGFloat) {
            let half = arrow.outline.width * unit / 2
            let tail = path.point(at: distance - half)
            let head = path.point(at: distance + half)
            self.arrow = arrow
            center = path.point(at: distance)
            angle = atan2(head.y - tail.y, head.x - tail.x)
            let reach = arrow.haloRadius * unit
            let height = arrow.outline.height * unit
            let outline = CGRect(x: -half, y: -height / 2, width: 2 * half, height: height)
            frame = outline.insetBy(dx: -reach, dy: -reach)
                .applying(CGAffineTransform(translationX: center.x, y: center.y).rotated(by: angle))
        }
    }

    /// The arrows placed on one tile.
    struct Layout {
        private(set) var placements: [Placement] = []

        /// Each line's arrows, in order, at as many of its marks inside the
        /// tile as find room.
        /// - Parameter unit: pixels for each pixel of the style's 256-pixel tile.
        init(_ lines: [OneWayLine], unit: CGFloat, room: inout VectorTilePoints.Room) {
            for line in lines {
                let arrow = line.kind.arrow
                let path = MeasuredPath(line.points)
                let width = arrow.outline.width * unit
                let margin = arrow.margin * unit
                let marks = VectorTileArrows.marks(
                    arrow.style,
                    length: path.length,
                    width: width,
                    spacing: VectorTileArrows.spacing * unit,
                    step: width / 4
                )
                // A mark outside the tile is the neighbouring tile's to draw.
                for mark in marks where room.bounds.contains(path.point(at: mark.distance)) {
                    let placement = mark.spots.lazy
                        .map { Placement(arrow: arrow, along: path, at: $0, unit: unit) }
                        .first { placement in
                            room.bounds.contains(placement.frame)
                                && room.isFree(placement.frame.insetBy(dx: -margin, dy: -margin))
                        }
                    guard let placement else { continue }
                    room.take(placement.frame)
                    placements.append(placement)
                }
            }
        }

        func draw(into context: CGContext, unit: CGFloat) {
            for placement in placements {
                let arrow = placement.arrow
                let path = arrow.outline.path(unit: unit)
                context.saveGState()
                context.translateBy(x: placement.center.x, y: placement.center.y)
                context.rotate(by: placement.angle)
                if arrow.haloRadius > 0 {
                    context.addPath(path)
                    context.setStrokeColor(VectorTileArrows.halo)
                    context.setLineWidth(2 * arrow.haloRadius * unit)
                    context.setLineJoin(.round)
                    context.strokePath()
                }
                context.addPath(path)
                context.setFillColor(arrow.color)
                context.fillPath()
                context.restoreGState()
            }
        }
    }

    // MARK: Helpers

    /// Ends closer than this are one point: the archive gives both ways the
    /// node they share, and only rounding parts them.
    private static let joinTolerance: CGFloat = 0.5

    private static func meets(_ end: CGPoint?, _ start: CGPoint?) -> Bool {
        guard let end, let start else { return false }
        return abs(end.x - start.x) <= joinTolerance && abs(end.y - start.y) <= joinTolerance
    }
}
