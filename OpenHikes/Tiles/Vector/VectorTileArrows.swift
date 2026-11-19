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
//  The arrows come from the vector extras' `oneways` layer, where every
//  one-way street and path is a line of its own, its nodes in OpenStreetMap's
//  order (`Scripts/lib/vector-extras.yml`). The basemap's roads carry
//  `oneway` too, but Planetiler merges a road's pieces into one line to build
//  them, and turns a piece around where that joins it, so an arrow along the
//  basemap's line can point back. An arrow points along the way where it is
//  `yes` and against it where it is `-1`, and a roundabout is one-way unless
//  tagged otherwise, as Carto takes one. A tile drawn without its extras has
//  no arrows.
//
//  Carto spaces the two kinds of arrow differently, because Mapnik places a
//  marker and a line's text by different rules (``Arrow/Style``), and both
//  rules are kept: a short one-way street has no arrow, and a short one-way
//  path has one. Each way is spaced on its own, as Mapnik spaces each of
//  Carto's lines. As with a name along a line, a tile draws only the arrows
//  whose marks lie inside it, and an arrow only where it lies wholly inside
//  the tile, clear of everything that claimed room before it — the streets'
//  names, which Carto places first — so no arrow is cut at a tile's edge.
//

import CoreGraphics
import Foundation

nonisolated enum VectorTileArrows {
    /// The vector extras' layer of one-way ways.
    static let layerName = "oneways"
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
        /// Footways, paths and steps.
        case footway
        case livingStreet
        /// Residential, unclassified, service and unknown roads.
        case minorRoad
        case motorway
        case pedestrian
        case primary
        case secondary
        case tertiary
        case track
        case trunk

        /// The more important first: the order their lines claim room in.
        static let importance: [Self] = [
            .motorway, .trunk, .primary, .secondary, .tertiary, .minorRoad, .livingStreet, .pedestrian,
            .footway, .cycleway, .track, .bridleway,
        ]

        /// The kind of a way by its `highway` tag, which the extras keep as
        /// its `kind`, or `nil` for one Carto draws no arrows along.
        init?(highway: String?) {
            guard let highway, let found = Self.byHighway[highway] else { return nil }
            self = found
        }

        /// The highways Carto draws arrows along, a link as its road. The
        /// extras keep these alone, listed under `&arrowed`.
        static let byHighway: [String: Self] = [
            "motorway": .motorway,
            "motorway_link": .motorway,
            "trunk": .trunk,
            "trunk_link": .trunk,
            "primary": .primary,
            "primary_link": .primary,
            "secondary": .secondary,
            "secondary_link": .secondary,
            "tertiary": .tertiary,
            "tertiary_link": .tertiary,
            "residential": .minorRoad,
            "unclassified": .minorRoad,
            "road": .minorRoad,
            "service": .minorRoad,
            "living_street": .livingStreet,
            "pedestrian": .pedestrian,
            "footway": .footway,
            "path": .footway,
            "steps": .footway,
            "cycleway": .cycleway,
            "track": .track,
            "bridleway": .bridleway,
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

    /// One of the extras' one-way ways, or the part of one a tile holds, its
    /// points in the order it is travelled, in the picture's pixels.
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

    /// The one-way ways `tile` offers at `target`'s zoom, each running the
    /// way it is travelled, the more important kind first.
    static func lines(
        in tile: MapboxVectorTile,
        source: VectorTileAddress,
        target: VectorTileAddress
    ) -> [OneWayLine] {
        guard target.z >= minimumZ, let layer = tile.layers[layerName] else { return [] }
        let geometry = VectorTileGeometry(extent: layer.extent, source: source, target: target)
        var ways: [Kind: [[CGPoint]]] = [:]
        for feature in layer.features where feature.type == .line {
            guard let kind = Kind(highway: feature.string("kind")) else { continue }
            switch feature.string("oneway") {
            case "yes": ways[kind, default: []] += geometry.lines(of: feature)
            case "-1": ways[kind, default: []] += geometry.lines(of: feature).map { $0.reversed() }
            default: continue
            }
        }
        return Kind.importance.flatMap { kind in
            (ways[kind] ?? []).filter { $0.count > 1 }.map { OneWayLine(kind: kind, points: $0) }
        }
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

        /// The arrow `distance` along `path`, turned as Mapnik turns it: a
        /// marker to the segment under its middle, and a line's text to the
        /// line between its tail and its head, which is that segment's way
        /// wherever the arrow lies along one.
        init(arrow: Arrow, along path: MeasuredPath, at distance: CGFloat, unit: CGFloat) {
            let half = arrow.outline.width * unit / 2
            self.arrow = arrow
            center = path.point(at: distance)
            switch arrow.style {
            case .marker:
                angle = path.segmentAngle(at: distance)
            case .text:
                let tail = path.point(at: distance - half)
                let head = path.point(at: distance + half)
                angle = atan2(head.y - tail.y, head.x - tail.x)
            }
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

}

nonisolated extension MeasuredPath {
    /// The way the segment under the point `distance` along the line runs,
    /// in radians from the picture's x axis, passing over segments of no
    /// length: the angle Mapnik turns a marker to.
    func segmentAngle(at distance: CGFloat) -> CGFloat {
        let segments = distances.indices.dropFirst().filter { distances[$0] > distances[$0 - 1] }
        guard let index = segments.first(where: { distances[$0] >= distance }) ?? segments.last else { return 0 }
        let from = points[index - 1]
        let to = points[index]
        return atan2(to.y - from.y, to.x - from.x)
    }
}
