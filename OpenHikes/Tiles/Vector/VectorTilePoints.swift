//
//  VectorTilePoints.swift
//  OpenHikes
//
//  The points on a drawn tile — car parks and fuel, summits and huts, shops,
//  stops, benches and gates — each with OpenStreetMap Carto's icon and, where
//  Carto writes one, its name under it (``VectorTilePointStyle``).
//
//  Room is claimed in the order Carto's layers claim it: the names of places
//  first, then the stations, then the points' icons, then the names along
//  roads and rivers, then the points' names, and last the low-priority icons
//  and their names. Within each, the higher summit goes first, as Carto
//  orders points by height, then the point the archive offers from a wider
//  zoom, which for an area is the larger; a station goes before a halt or a
//  tram stop, and those before a subway entrance. An icon and its name are
//  placed apart, as Carto's two layers place them, so a name can stand where
//  its icon found no room. A station's are placed together, its icon and then
//  its name, because one layer draws both.
//
//  As with every name, a point belongs to the tile its point lies in, and
//  what is drawn for it never crosses the tile's edge: near the edge it is
//  moved inward, by no more than it would have crossed.
//

import CoreGraphics
import CoreText
import Foundation

/// What a tile's points are drawn from: Carto's table and its icons.
nonisolated struct VectorTilePointSet: Sendable {
    let style: VectorTilePointStyle
    let icons: any VectorTileIconDrawing

    static let standard = Self(style: .bundled, icons: CatalogIcons.shared)
}

nonisolated enum VectorTilePoints {
    struct Candidate {
        /// Where the point is, in the picture's pixels.
        let anchor: CGPoint
        /// The label's lines as written: the name, and a height under it
        /// where Carto writes one, which stands alone under a point with no
        /// name, as in Carto. Empty for a point drawn without either.
        let lines: [String]
        let look: VectorTilePointStyle.Look
        let rank: Rank
    }

    /// Carto's order: a station before a halt or a tram stop and those
    /// before a subway entrance, the highest summit first, then the larger
    /// area, and the rest settled the same way on every tile.
    struct Rank: Comparable {
        /// The point's place in its layer's own order, as
        /// ``VectorTilePointStyle/Look/stationOrder`` gives it; 0 for a
        /// point with none.
        let order: Int
        let height: Double
        let minimumZoom: Double
        let name: String
        let x: CGFloat
        let y: CGFloat

        static func < (lhs: Self, rhs: Self) -> Bool {
            let left = (lhs.order, -lhs.height, lhs.minimumZoom, lhs.name, lhs.x, lhs.y)
            return left < (rhs.order, -rhs.height, rhs.minimumZoom, rhs.name, rhs.x, rhs.y)
        }
    }

    /// The kinds Carto orders by height.
    private static let rankedByHeight: Set<String> = ["peak", "volcano", "saddle"]

    // MARK: Choosing

    /// The points `tile` offers at `target`'s zoom whose positions lie on
    /// the picture of it, in the order they claim room. A point beyond is
    /// the neighbouring tile's to draw.
    /// - Parameter height: a height in meters as the reader reads one.
    static func candidates(
        in tile: MapboxVectorTile,
        source: VectorTileAddress,
        target: VectorTileAddress,
        language: String,
        height: (Double) -> String,
        style: VectorTilePointStyle
    ) -> [Candidate] {
        guard let layer = tile.layers["pois"] else { return [] }
        let side = CGFloat(VectorTileRasterizer.pixelSize)
        let bounds = CGRect(x: 0, y: 0, width: side, height: side)
        let geometry = VectorTileGeometry(extent: layer.extent, source: source, target: target)
        var found: [Candidate] = []
        for feature in layer.features where feature.type == .point {
            guard let kind = feature.string("kind") else { continue }
            let name = VectorTileLabels.name(of: feature, language: language)
            let detail = feature.string("kind_detail")
            guard let look = style.look(
                kind: kind,
                detail: detail,
                named: name != nil,
                z: target.z,
                access: feature.string("access")
            ) else { continue }
            let elevation = feature.number("elevation")
            var lines: [String] = []
            if look.text != nil {
                if let name { lines.append(name) }
                if look.showsElevation, let elevation { lines.append(height(elevation)) }
            }
            guard !look.icons.isEmpty || !lines.isEmpty else { continue }
            for point in geometry.points(of: feature) where bounds.contains(point) {
                found.append(Candidate(anchor: point, lines: lines, look: look, rank: Rank(
                    order: look.stationOrder ?? 0,
                    height: rankedByHeight.contains(kind) ? elevation ?? -.infinity : -.infinity,
                    minimumZoom: feature.number("min_zoom") ?? .infinity,
                    name: name ?? "",
                    x: point.x,
                    y: point.y
                )))
            }
        }
        return found.sorted { $0.rank < $1.rank }
    }

    // MARK: Placing

    /// The room taken on one tile, by names and icons alike.
    struct Room {
        let bounds: CGRect
        private(set) var taken: [CGRect]

        init(bounds: CGRect, taken: [CGRect]) {
            self.bounds = bounds
            self.taken = taken
        }

        /// `frame` moved inside the tile, by no more than it crossed the
        /// edge, or `nil` where it is larger than the tile.
        func inside(_ frame: CGRect) -> CGRect? {
            guard frame.width <= bounds.width, frame.height <= bounds.height else { return nil }
            return frame.offsetBy(
                dx: max(bounds.minX - frame.minX, 0) + min(bounds.maxX - frame.maxX, 0),
                dy: max(bounds.minY - frame.minY, 0) + min(bounds.maxY - frame.maxY, 0)
            )
        }

        func isFree(_ frame: CGRect) -> Bool {
            !taken.contains { $0.intersects(frame) }
        }

        mutating func take(_ frame: CGRect) {
            taken.append(frame)
        }
    }

    /// The icons placed on one tile.
    struct Icons {
        private var placed: [(icon: VectorTilePointStyle.Icon, frame: CGRect)] = []

        /// How many points got their icons.
        private(set) var count = 0

        /// Where each icon stands, in the picture's pixels.
        var frames: [CGRect] { placed.map(\.frame) }

        /// Each candidate's icons centred on its point, where they find room.
        /// - Parameter unit: pixels for each pixel of the style's 256-pixel tile.
        init(_ candidates: [Candidate], unit: CGFloat, room: inout Room) {
            for candidate in candidates {
                place(candidate, unit: unit, room: &room)
            }
        }

        /// The candidate's icons centred on its point, where they find room.
        mutating func place(_ candidate: Candidate, unit: CGFloat, room: inout Room) {
            guard !candidate.look.icons.isEmpty else { return }
            let iconFrames = candidate.look.icons.map { icon in
                CGRect(
                    x: candidate.anchor.x - icon.size.width * unit / 2,
                    y: candidate.anchor.y - icon.size.height * unit / 2,
                    width: icon.size.width * unit,
                    height: icon.size.height * unit
                )
            }
            let whole = iconFrames.dropFirst().reduce(iconFrames[0]) { $0.union($1) }
            guard let moved = room.inside(whole) else { return }
            let shift = CGPoint(x: moved.minX - whole.minX, y: moved.minY - whole.minY)
            let lead = candidate.look.icons[0]
            guard lead.allowsOverlap || room.isFree(moved) else { return }
            if !lead.ignoresPlacement { room.take(moved) }
            for (icon, frame) in zip(candidate.look.icons, iconFrames) {
                placed.append((icon, frame.offsetBy(dx: shift.x, dy: shift.y)))
            }
            count += 1
        }

        func draw(into context: CGContext, icons: any VectorTileIconDrawing) {
            for (icon, frame) in placed {
                context.saveGState()
                context.setAlpha(icon.opacity)
                if let asset = icon.asset {
                    if let image = icons.image(asset: asset, fill: icon.fill, size: frame.size) {
                        // The picture's rows run up; the tile's down.
                        context.translateBy(x: frame.minX, y: frame.maxY)
                        context.scaleBy(x: 1, y: -1)
                        context.draw(image, in: CGRect(origin: .zero, size: frame.size))
                    }
                } else {
                    context.setFillColor(icon.fill ?? VectorTileStyle.color("#0000FF"))
                    context.fillEllipse(in: frame)
                    if let outline = icon.outline {
                        context.setStrokeColor(outline.color)
                        context.setLineWidth(outline.width * frame.width / max(icon.size.width, 1))
                        context.strokeEllipse(in: frame)
                    }
                }
                context.restoreGState()
            }
        }
    }

    /// The points' names placed on one tile.
    struct Names {
        private var placed: [(block: NameBlock, frame: CGRect)] = []

        var count: Int { placed.count }

        /// Where each name stands, in the picture's pixels.
        var frames: [CGRect] { placed.map(\.frame) }

        /// Each candidate's name under, over or on its point, as its style
        /// offsets it, where it finds room.
        init(_ candidates: [Candidate], unit: CGFloat, room: inout Room, fonts: inout LabelFonts) {
            for candidate in candidates {
                place(candidate, unit: unit, room: &room, fonts: &fonts)
            }
        }

        /// The candidate's name under, over or on its point, as its style
        /// offsets it, where it finds room.
        mutating func place(_ candidate: Candidate, unit: CGFloat, room: inout Room, fonts: inout LabelFonts) {
            guard !candidate.lines.isEmpty, let style = candidate.look.text else { return }
            let block = NameBlock(candidate.lines, style: style, unit: unit, fonts: &fonts)
            let size = block.size
            let offset = style.offset * unit
            let top = offset > 0 ? candidate.anchor.y + offset
                : offset < 0 ? candidate.anchor.y + offset - size.height
                : candidate.anchor.y - size.height / 2
            let left = candidate.anchor.x - size.width / 2
            let frame = CGRect(x: left, y: top, width: size.width, height: size.height)
            guard let moved = room.inside(frame), room.isFree(moved) else { return }
            room.take(moved)
            placed.append((block, moved))
        }

        func draw(into context: CGContext) {
            context.saveGState()
            context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            context.setLineJoin(.round)
            for (block, frame) in placed {
                block.draw(in: frame, context: context)
            }
            context.restoreGState()
        }
    }

    /// Carto's stations placed on one tile, as the one layer that draws both
    /// their icons and their names places them: each station's icon, then
    /// its name, before the next station's.
    struct Stations {
        private(set) var icons: Icons
        private(set) var names: Names

        init(_ candidates: [Candidate], unit: CGFloat, room: inout Room, fonts: inout LabelFonts) {
            icons = Icons([], unit: unit, room: &room)
            names = Names([], unit: unit, room: &room, fonts: &fonts)
            for candidate in candidates {
                icons.place(candidate, unit: unit, room: &room)
                names.place(candidate, unit: unit, room: &room, fonts: &fonts)
            }
        }
    }

    /// `text` broken between words as Mapnik breaks a name: a line ends once
    /// it is wider than `width`, after the word that made it so. So a word
    /// wider than the width stands alone, and two short words share a line.
    static func wrapped(_ text: String, width: CGFloat, measure: (String) -> CGFloat) -> [String] {
        let words = text.split(separator: " ").map(String.init)
        guard width > 0, words.count > 1 else { return [text] }
        var lines: [String] = []
        var line = ""
        for word in words {
            line = line.isEmpty ? word : line + " " + word
            if measure(line) > width {
                lines.append(line)
                line = ""
            }
        }
        if !line.isEmpty { lines.append(line) }
        return lines
    }
}

/// A point's name, broken into lines and set in its style.
nonisolated private struct NameBlock {
    let lines: [InkedText]
    let lineSpacing: CGFloat
    let opacity: CGFloat

    var size: CGSize {
        CGSize(
            width: lines.map(\.width).max() ?? 0,
            height: lines.reduce(0) { $0 + $1.ascent + $1.descent } + lineSpacing * CGFloat(max(lines.count - 1, 0))
        )
    }

    init(_ text: [String], style: VectorTilePointStyle.Text, unit: CGFloat, fonts: inout LabelFonts) {
        let font = fonts.font(size: style.size * unit, face: style.face)
        let set = { (line: String) in
            InkedText(
                line,
                font: font,
                color: style.color,
                unit: unit,
                halo: style.halo,
                haloWidth: style.haloRadius
            )
        }
        let width = style.wrapWidth * unit
        let key = NSAttributedString.Key(kCTFontAttributeName as String)
        let measure = { (line: String) in
            CGFloat(CTLineGetTypographicBounds(
                CTLineCreateWithAttributedString(NSAttributedString(string: line, attributes: [key: font])),
                nil,
                nil,
                nil
            ))
        }
        lines = text.flatMap { VectorTilePoints.wrapped($0, width: width, measure: measure) }.map(set)
        lineSpacing = style.lineSpacing * unit
        opacity = style.opacity
    }

    /// Each line centred in `frame`, its halo first.
    func draw(in frame: CGRect, context: CGContext) {
        context.saveGState()
        context.setAlpha(opacity)
        var top = frame.minY
        for line in lines {
            let baseline = CGPoint(x: frame.midX - line.width / 2, y: top + line.ascent)
            line.drawHalo(at: baseline, context: context)
            line.drawInk(at: baseline, context: context)
            top += line.ascent + line.descent + lineSpacing
        }
        context.restoreGState()
    }
}
