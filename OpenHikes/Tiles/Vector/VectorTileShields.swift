//
//  VectorTileShields.swift
//  OpenHikes
//
//  The numbers of roads on a drawn tile: “A 3”, “B 43”, “NY 495”, each in a
//  small plate on its road, as OpenStreetMap Carto's `roads-text-ref` layers
//  draw them (`roads.mss`). A plate takes its road's colors, a motorway's
//  from zoom 10, a trunk or a primary road's from 11, a secondary road's
//  from 12 and a tertiary road's from 13, and a road that carries two
//  numbers shows one under the other.
//
//  A road arrives as many short ways. Pieces with the same number that meet
//  end to end are joined first, as the names along lines are
//  (``VectorTileLineLabels``). Carto sets a road's plates a fixed distance
//  apart along it, on a picture many tiles wide; a tile here is drawn alone,
//  and sees only the stretch of road that crosses it. So a plate stands
//  where its road crosses a line of a grid laid over the whole world
//  (``spacing``), which every tile works out alike: a road keeps an even
//  spacing however it is cut into tiles, and no tile needs to know what the
//  next one placed. A plate slides along its road to stay clear of what was
//  placed before it and of the tile's edge, which none crosses, and stands
//  upright whichever way its road runs.
//

import Algorithms
import CoreGraphics
import CoreText
import Foundation

nonisolated enum VectorTileShields {
    /// The property the archive keeps a road's number in.
    static let refKey = "ref"

    /// The roads Carto gives a plate, most important first.
    enum Road: Int, CaseIterable, Comparable, Sendable {
        case motorway = 0
        case primary = 2
        case secondary = 3
        case tertiary = 4
        case trunk = 1

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

        /// The road a feature of the `roads` layer is, or `nil` for one
        /// Carto gives no plate: a link, a street, a path.
        static func road(kind: String?, detail: String?) -> Self? {
            switch (kind, detail) {
            case ("highway", "motorway"): .motorway
            case ("major_road", "trunk"): .trunk
            case ("major_road", "primary"): .primary
            case ("major_road", "secondary"): .secondary
            case ("major_road", "tertiary"): .tertiary
            default: nil
            }
        }

        /// The first zoom the road's number is shown at.
        var firstZ: Int {
            switch self {
            case .motorway: 10
            case .trunk, .primary: 11
            case .secondary: 12
            case .tertiary: 13
            }
        }

        /// The plate's fill, its edge and its letters: the road's surface,
        /// its casing and Carto's shield ink for it.
        var colors: (fill: CGColor, edge: CGColor, ink: CGColor) {
            let hexes: (String, String, String) = switch self {
            case .motorway: ("#E892A2", "#DC2A67", "#620728")
            case .trunk: ("#F9B29C", "#C84E2F", "#5F1C0C")
            case .primary: ("#FCD6A4", "#A06B00", "#503000")
            case .secondary: ("#F7FABF", "#707D05", "#364000")
            case .tertiary: ("#FFFFFF", "#8F8F8F", "#3B3B3B")
            }
            return (VectorTileStyle.color(hexes.0), VectorTileStyle.color(hexes.1), VectorTileStyle.color(hexes.2))
        }
    }

    /// One road's numbered ways, joined end to end, in the picture's pixels.
    struct NumberedLine: Equatable {
        let road: Road
        /// The road's numbers, one to a line of the plate.
        let numbers: [String]
        let points: [CGPoint]
        let length: CGFloat
    }

    /// The numbers a road's `ref` holds, one for each line of its plate, or
    /// none where Carto draws no plate: more than ``mostNumbers`` of them,
    /// or one longer than ``longestNumber``.
    static func numbers(in ref: String) -> [String] {
        let numbers = ref.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !numbers.isEmpty, numbers.count <= mostNumbers, numbers.allSatisfy({ $0.count <= longestNumber }) else {
            return []
        }
        return numbers
    }

    /// The numbered roads `tile` offers at `target`'s zoom, joined, the more
    /// important road first and the longer first among its like.
    static func lines(
        in tile: MapboxVectorTile,
        source: VectorTileAddress,
        target: VectorTileAddress
    ) -> [NumberedLine] {
        guard let layer = tile.layers["roads"] else { return [] }
        let geometry = VectorTileGeometry(extent: layer.extent, source: source, target: target)
        var pieces: [Key: [[CGPoint]]] = [:]
        for feature in layer.features where feature.type == .line {
            guard let road = Road.road(kind: feature.string("kind"), detail: feature.string("kind_detail")),
                  target.z >= road.firstZ,
                  let ref = feature.string(refKey)
            else { continue }
            let numbers = numbers(in: ref)
            guard !numbers.isEmpty else { continue }
            pieces[Key(road: road, numbers: numbers), default: []] += geometry.lines(of: feature)
        }
        let lines = pieces.flatMap { key, parts in
            VectorTileLineLabels.joined(parts).map { points in
                NumberedLine(
                    road: key.road,
                    numbers: key.numbers,
                    points: points,
                    length: VectorTileLineLabels.length(of: points)
                )
            }
        }
        return lines.sorted { lhs, rhs in
            if lhs.road != rhs.road { return lhs.road < rhs.road }
            if lhs.length != rhs.length { return lhs.length > rhs.length }
            let (left, right) = (lhs.points.first ?? .zero, rhs.points.first ?? .zero)
            return (lhs.numbers.joined(), left.x, left.y) < (rhs.numbers.joined(), right.x, right.y)
        }
    }

    /// The size of a number's letters at `z`, in the pixels of a 256-pixel
    /// tile: Carto's `@shield-size`.
    static func textSize(at z: Int) -> CGFloat {
        z >= VectorTileStyle.z18 ? 12 : z >= 16 ? 11 : 10
    }

    /// The most numbers on one plate, and the most characters in one: the
    /// largest plate Carto has a picture for.
    static let mostNumbers = 4
    static let longestNumber = 11
    /// How far apart the lines of the grid stand that a road gets a plate
    /// for crossing: half Carto's `@shield-spacing` of 760. Carto's suits a
    /// desktop's window; a phone shows a tile and a half across, and at
    /// Carto's spacing most of its screens would show a road no number.
    static let spacing: CGFloat = 380
    /// Carto's `@shield-repeat-distance`: the least distance between two
    /// plates of one number, which keeps a motorway's two carriageways from
    /// each showing it side by side.
    static let repeatDistance: CGFloat = 400
    /// The room a plate keeps from everything placed before it.
    static let margin: CGFloat = 8
    /// Around the letters, inside the plate's edge.
    static let padding = CGSize(width: 4, height: 3)
    static let cornerRadius: CGFloat = 2

    /// A place where a line crosses the grid.
    struct GridCrossing: Equatable {
        /// How far along the line.
        let distance: CGFloat
        /// Whether the grid's line it crosses runs down the map.
        let isDown: Bool
        /// Where that grid line lies, across the map for one that runs down
        /// it and down the map for one across, in the world's pixels at the
        /// zoom drawn: a whole multiple of the spacing, and exact where the
        /// crossing worked out along the line is not.
        let line: CGFloat

        /// Whether the tile whose picture has its corner at `origin` on the
        /// grid and its frame at `bounds` holds the crossing, which stands
        /// at `point` on that picture. On the grid line's own axis the
        /// line's exact place decides: every so many tiles a grid line runs
        /// along a seam, and the point worked out along the line lands a
        /// rounding either side of it, so both tiles beside the seam, or
        /// neither, would take it.
        func isHeld(at point: CGPoint, origin: CGPoint, in bounds: CGRect) -> Bool {
            let exact = isDown ? CGPoint(x: line - origin.x, y: point.y) : CGPoint(x: point.x, y: line - origin.y)
            return bounds.contains(exact)
        }
    }

    /// Each place along `points` where the line crosses the grid: the lines
    /// `spacing` apart, across and down, of a grid whose origin lies
    /// `origin` before the points' own, so that two tiles that hold the same
    /// road agree on its crossings. Nearest the line's start first.
    static func gridCrossings(of points: [CGPoint], origin: CGPoint, every spacing: CGFloat) -> [GridCrossing] {
        guard spacing > 0 else { return [] }
        var found: [GridCrossing] = []
        var covered: CGFloat = 0
        for (from, to) in points.adjacentPairs() {
            let length = hypot(to.x - from.x, to.y - from.y)
            defer { covered += length }
            let runs = [(origin.x + from.x, origin.x + to.x, true), (origin.y + from.y, origin.y + to.y, false)]
            for (start, end, isDown) in runs where start != end {
                let first = Int((min(start, end) / spacing).rounded(.up))
                let last = Int((max(start, end) / spacing).rounded(.down))
                guard first <= last else { continue }
                for index in first...last {
                    let line = CGFloat(index) * spacing
                    let share = (line - start) / (end - start)
                    if share >= 0, share < 1 {
                        found.append(GridCrossing(distance: covered + share * length, isDown: isDown, line: line))
                    }
                }
            }
        }
        return found.sorted { $0.distance < $1.distance }
    }

    private struct Key: Hashable {
        let road: Road
        let numbers: [String]
    }
}

// MARK: - Placing and drawing

nonisolated extension VectorTileShields {
    /// The plates placed on one tile.
    struct Layout {
        private var plates: [Plate] = []

        /// Where each plate stands, in the picture's pixels.
        var frames: [CGRect] { plates.map(\.frame) }

        /// Each line's plates where it crosses the world's grid inside the
        /// tile `target` and finds room, with `unit` pixels for each pixel of
        /// the style's tile.
        init(
            _ lines: [NumberedLine],
            target: VectorTileAddress,
            unit: CGFloat,
            room: inout VectorTilePoints.Room,
            fonts: inout LabelFonts
        ) {
            let font = fonts.font(size: textSize(at: target.z) * unit, face: .regular)
            let origin = CGPoint(x: CGFloat(target.x) * room.bounds.width, y: CGFloat(target.y) * room.bounds.height)
            var placedAt: [[String]: [CGPoint]] = [:]
            for line in lines {
                let colors = line.road.colors
                let palette = fonts.palette
                let rows = line.numbers.map { number in
                    InkedText(number, font: font, color: colors.ink, unit: unit, haloWidth: 0, palette: palette)
                }
                let size = CGSize(
                    width: (rows.map(\.width).max() ?? 0) + 2 * padding.width * unit,
                    height: rows.reduce(0) { $0 + $1.ascent + $1.descent } + 2 * padding.height * unit
                )
                let path = MeasuredPath(line.points)
                let slides: [CGFloat] = [0, 1, -1, 2, -2].map { $0 * size.width / 2 }
                // A crossing outside the tile is the neighbouring tile's.
                for crossing in gridCrossings(of: line.points, origin: origin, every: spacing * unit)
                where crossing.isHeld(at: path.point(at: crossing.distance), origin: origin, in: room.bounds) {
                    for slide in slides {
                        let center = path.point(at: crossing.distance + slide)
                        let frame = CGRect(
                            x: center.x - size.width / 2,
                            y: center.y - size.height / 2,
                            width: size.width,
                            height: size.height
                        )
                        let nearSame = placedAt[line.numbers, default: []].contains { spot in
                            hypot(spot.x - center.x, spot.y - center.y) < repeatDistance * unit
                        }
                        guard !nearSame else { break }
                        guard room.bounds.contains(frame),
                              room.isFree(frame.insetBy(dx: -margin * unit, dy: -margin * unit))
                        else { continue }
                        room.take(frame)
                        placedAt[line.numbers, default: []].append(center)
                        // The plate is the road's own surface and casing.
                        plates.append(Plate(
                            frame: frame,
                            rows: rows,
                            fill: palette.color(colors.fill, as: .surface),
                            edge: palette.color(colors.edge, as: .casing)
                        ))
                        break
                    }
                }
            }
        }

        func draw(into context: CGContext, unit: CGFloat) {
            context.saveGState()
            context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            for plate in plates {
                let edge = unit
                let box = plate.frame.insetBy(dx: edge / 2, dy: edge / 2)
                let radius = cornerRadius * unit
                let outline = CGPath(roundedRect: box, cornerWidth: radius, cornerHeight: radius, transform: nil)
                context.addPath(outline)
                context.setFillColor(plate.fill)
                context.fillPath()
                context.addPath(outline)
                context.setStrokeColor(plate.edge)
                context.setLineWidth(edge)
                context.strokePath()
                var top = plate.frame.minY + padding.height * unit
                for row in plate.rows {
                    row.drawInk(at: CGPoint(x: plate.frame.midX - row.width / 2, y: top + row.ascent), context: context)
                    top += row.ascent + row.descent
                }
            }
            context.restoreGState()
        }
    }

    private struct Plate {
        let frame: CGRect
        let rows: [InkedText]
        let fill: CGColor
        let edge: CGColor
    }
}
