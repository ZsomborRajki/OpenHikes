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
//  orders points by height, then the larger area, then the point the archive
//  offers from a wider zoom; a station goes before a halt or a tram stop, and
//  those before a subway entrance. An icon and its name are
//  placed apart, as Carto's two layers place them, so a name can stand where
//  its icon found no room. A station's are placed together, its icon and then
//  its name, because one layer draws both.
//
//  An area — a forest, a park, a car park — is a point inside it. The vector
//  extras give one with the area's size, which Carto draws it by: named from
//  a wider zoom and larger the larger the area. The basemap gives most of the
//  same areas' points, without a size, at the same spot, both being cut from
//  one OpenStreetMap area by Planetiler; where the extras give an area's
//  point, the basemap's is left out.
//
//  The extras also give the points the basemap files unlike Carto, or later:
//  a hut the basemap takes for a restaurant, a castle it takes for an
//  attraction, a station it keeps without the tag that says it is a
//  subway's. There too the basemap's point of the same name at the same spot
//  is left out (``Superseded``).
//
//  As with every name, a point belongs to the tile its point lies in, and
//  what is drawn for it, a name's halo included, never crosses the tile's
//  edge: near the edge it is moved inward, by no more than it would have
//  crossed.
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
        /// The area's size on the picture, Carto's `way_pixels`; 0 for a
        /// point, which Carto counts as no size.
        var pixels: Double = 0
        let minimumZoom: Double
        let name: String
        let x: CGFloat
        let y: CGFloat

        /// Whether the point is one Carto orders by height, and has one: a
        /// summit, a volcano, a saddle or a pass.
        var isByHeight: Bool { height > -.infinity }

        static func < (lhs: Self, rhs: Self) -> Bool {
            let (left, right) = ((lhs.order, -lhs.height, -lhs.pixels), (rhs.order, -rhs.height, -rhs.pixels))
            guard left == right else { return left < right }
            return (lhs.minimumZoom, lhs.name, lhs.x, lhs.y) < (rhs.minimumZoom, rhs.name, rhs.x, rhs.y)
        }
    }

    /// The kinds Carto orders by height.
    private static let rankedByHeight: Set<String> = ["peak", "volcano", "saddle", "mountain_pass"]

    /// The kinds of point the vector extras file as Carto files them where
    /// the basemap's own point for the same thing may say otherwise, so the
    /// extras' stands in its place: a mountain hut, which the basemap files
    /// by its `amenity` where it has one; Carto's stops, which the basemap
    /// keeps without their `station` tag; and the historic kinds the basemap
    /// files as an attraction where they are tagged as one too.
    static let supersedingKinds: Set<String> = [
        "alpine_hut", "wilderness_hut", "station", "halt", "tram_stop",
        "castle", "fort", "manor", "monument", "memorial", "archaeological_site", "city_gate", "wayside_cross",
        "wayside_shrine",
    ]

    /// The basemap's kind for a named street or square mapped as an area,
    /// whose name Carto writes inside it (``VectorTilePointStyle/square(z:firstZoom:)``).
    static let squareKind = "pedestrian"

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
        let superseded = Superseded(layer.features, geometry: geometry)
        var found: [Candidate] = []
        for feature in layer.features where feature.type == .point {
            guard let kind = feature.string("kind"), !superseded.repeats(feature) else { continue }
            let name = VectorTileLabels.name(of: feature, language: language)
            let detail = feature.string("kind_detail")
            let pixels = feature.number(sizeKey).map { $0 * pow(4, Double(target.z)) }
            let square = kind == squareKind && name != nil
                ? VectorTilePointStyle.square(z: target.z, firstZoom: feature.number("min_zoom"))
                : nil
            guard let look = square ?? style.look(
                kind: kind,
                detail: detail,
                named: name != nil,
                z: target.z,
                access: feature.string("access"),
                pixels: pixels
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
                    pixels: pixels ?? 0,
                    minimumZoom: feature.number("min_zoom") ?? .infinity,
                    name: name ?? "",
                    x: point.x,
                    y: point.y
                )))
            }
        }
        return found.sorted { $0.rank < $1.rank }
    }

    /// The property the vector extras give an area's size in: the square
    /// pixels it covers of the whole world drawn as one 256-pixel tile, so
    /// 4 to the power of a zoom times it at that zoom.
    static let sizeKey = "area"

    /// The points of the vector extras that stand in the basemap's place,
    /// to tell the basemap's point for the same thing: an area the extras
    /// give with its size, and a point of one of the ``supersedingKinds``.
    /// The same OpenStreetMap element is the same thing, named or not; the
    /// same name at the same spot is too, which on the live tiles has only
    /// ever paired a point with its own element, and holds for a point
    /// either archive gives without its id.
    private struct Superseded {
        private let elements: Set<UInt64>
        private let spots: [String: [CGPoint]]
        private let geometry: VectorTileGeometry
        /// How far apart two points of one thing may stand: two steps of the
        /// archive's grid. Both archives put it on the same step.
        private let reach: CGFloat

        init(_ features: [MapboxVectorTile.Feature], geometry: VectorTileGeometry) {
            var ids: Set<UInt64> = []
            var found: [String: [CGPoint]] = [:]
            for feature in features where feature.type == .point && Self.supersedes(feature) {
                if feature.isFromExtras, let id = feature.id.flatMap(Self.basemapID(ofExtras:)) {
                    ids.insert(id)
                }
                guard let name = feature.string("name") else { continue }
                found[name, default: []] += geometry.points(of: feature)
            }
            elements = ids
            spots = found
            self.geometry = geometry
            reach = 2 * geometry.scale
        }

        /// Whether `feature` is the basemap's point for a thing the extras
        /// give in its place: the same element, or the same name at the same
        /// spot, and itself neither sized nor the extras'.
        func repeats(_ feature: MapboxVectorTile.Feature) -> Bool {
            guard !Self.supersedes(feature) else { return false }
            if !feature.isFromExtras, let id = feature.id, elements.contains(id) { return true }
            guard let name = feature.string("name"), let named = spots[name] else { return false }
            return geometry.points(of: feature).contains { point in
                named.contains { abs($0.x - point.x) <= reach && abs($0.y - point.y) <= reach }
            }
        }

        private static func supersedes(_ feature: MapboxVectorTile.Feature) -> Bool {
            if feature.number(sizeKey) != nil { return true }
            guard feature.isFromExtras, let kind = feature.string("kind") else { return false }
            return supersedingKinds.contains(kind)
        }

        /// The basemap's id for the element an extras' point was cut from.
        /// Planetiler gives each of the extras' points the element's
        /// OpenStreetMap id times ten, plus 1 for a node, 2 for a way and 3
        /// for a relation; the basemap gives it the same id with the 1, 2 or
        /// 3 written above it (``VectorTileAreaDetails``).
        static func basemapID(ofExtras id: UInt64) -> UInt64? {
            let (element, type) = id.quotientAndRemainder(dividingBy: 10)
            guard (1...3).contains(type), element < 1 << elementTypeShift else { return nil }
            return type << elementTypeShift | element
        }

        /// The bit the basemap writes an element's type from.
        private static let elementTypeShift: UInt64 = 44
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

        /// Where the candidate's icons stand centred on its point, before
        /// the tile's edge moves them in, and the room they take together;
        /// `nil` for a point with no icon.
        static func frames(of candidate: Candidate, unit: CGFloat) -> (icons: [CGRect], whole: CGRect)? {
            let standing = candidate.look.icons.map { icon in
                CGRect(
                    x: candidate.anchor.x - icon.size.width * unit / 2,
                    y: candidate.anchor.y - icon.size.height * unit / 2,
                    width: icon.size.width * unit,
                    height: icon.size.height * unit
                )
            }
            guard let first = standing.first else { return nil }
            return (standing, standing.dropFirst().reduce(first) { $0.union($1) })
        }

        /// The candidate's icons centred on its point, where they find room.
        mutating func place(_ candidate: Candidate, unit: CGFloat, room: inout Room) {
            guard let (iconFrames, whole) = Self.frames(of: candidate, unit: unit),
                  let moved = room.inside(whole)
            else { return }
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
        /// - Parameter margin: the room each name keeps from everything
        ///   placed before it and from the tile's edge, in the picture's
        ///   pixels.
        init(
            _ candidates: [Candidate],
            unit: CGFloat,
            room: inout Room,
            fonts: inout LabelFonts,
            margin: CGFloat = 0
        ) {
            for candidate in candidates {
                place(candidate, unit: unit, room: &room, fonts: &fonts, margin: margin)
            }
        }

        /// The candidate's name under, over or on its point, as its style
        /// offsets it, where it finds room `margin` pixels clear of
        /// everything placed before it. Near the edge it is moved inward
        /// until its halo, and `margin` beyond it, are inside the tile: the
        /// tile beside cannot finish a halo cut at the edge, and its own
        /// names cannot see this one, so the margin keeps two names either
        /// side of the edge apart, as the names along lines keep theirs.
        ///
        /// A name the edge would move back over its own point goes on the
        /// point's other side instead, where it fits there: a summit near
        /// the foot of its tile is named above its triangle, which would
        /// otherwise take the room and leave it unnamed until a zoom whose
        /// tiles are cut elsewhere. It stands as far from the icon there as
        /// it would have here, the icon having been moved in too.
        mutating func place(
            _ candidate: Candidate,
            unit: CGFloat,
            room: inout Room,
            fonts: inout LabelFonts,
            margin: CGFloat = 0
        ) {
            guard !candidate.lines.isEmpty, let style = candidate.look.text else { return }
            let block = NameBlock(candidate.lines, style: style, unit: unit, fonts: &fonts)
            let reach = style.haloRadius * unit + margin
            let offset = style.offset * unit
            let size = block.size
            guard let styled = Self.fitted(size, at: candidate.anchor, offset: offset, reach: reach, in: room) else {
                return
            }
            var frame = styled.frame
            if styled.isPushedBack {
                let icons = Icons.frames(of: candidate, unit: unit)?.whole
                let lift = icons.flatMap { whole in room.inside(whole).map { $0.minY - whole.minY } } ?? 0
                let icon = CGPoint(x: candidate.anchor.x, y: candidate.anchor.y + lift)
                if let other = Self.fitted(size, at: icon, offset: -offset, reach: reach, in: room),
                   !other.isPushedBack, room.isFree(other.frame.insetBy(dx: -margin, dy: -margin)) {
                    frame = other.frame
                }
            }
            guard room.isFree(frame.insetBy(dx: -margin, dy: -margin)) else { return }
            room.take(frame)
            placed.append((block, frame))
        }

        /// Where a name of `size` stands by the point at `anchor`, moved
        /// inside the tile with `reach` to spare, or `nil` for one larger
        /// than the tile: its top `offset` below the point, its foot that
        /// far above it where the offset is negative, and centred on the
        /// point where there is none. And whether the edge pushed it back
        /// towards its point.
        private static func fitted(
            _ size: CGSize,
            at anchor: CGPoint,
            offset: CGFloat,
            reach: CGFloat,
            in room: Room
        ) -> (frame: CGRect, isPushedBack: Bool)? {
            let top = offset > 0 ? anchor.y + offset
                : offset < 0 ? anchor.y + offset - size.height
                : anchor.y - size.height / 2
            let frame = CGRect(x: anchor.x - size.width / 2, y: top, width: size.width, height: size.height)
            guard let inside = room.inside(frame.insetBy(dx: -reach, dy: -reach)) else { return nil }
            let moved = inside.insetBy(dx: reach, dy: reach)
            return (moved, offset > 0 ? moved.minY < frame.minY : offset < 0 && moved.maxY > frame.maxY)
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
        let measure = { (line: String) in InkedText.width(of: line, font: font) }
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
