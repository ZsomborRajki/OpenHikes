//
//  VectorTileLabels.swift
//  OpenHikes
//
//  The names on a drawn tile: places, summits and passes with their heights,
//  huts, lakes and glaciers. Each is in the app's language where the map has
//  the name in it, and in the local one where it does not, which for a hamlet
//  or a hut is always.
//
//  Each tile places its own names, and never one that crosses its edge. Tiles
//  are drawn one at a time from one archive tile each, so a name cut at an
//  edge could not be finished by the tile beside it. A name near an edge is
//  moved inward to fit, and one that cannot fit is left for a deeper zoom:
//  the trade OpenStreetMap's own renderer makes at the edges of the blocks it
//  draws. Which name wins where two would overlap is decided the same way on
//  every tile — by ``VectorTileLabelStyle/Category``, then the archive's own
//  ranking — so a zoom reads the same wherever it is drawn.
//

import CoreGraphics
import CoreText
import Foundation

nonisolated enum VectorTileLabels {
    /// The language the app is showing, whose names the map prefers.
    static var appLanguage: String { Bundle.main.preferredLocalizations.first ?? "en" }

    /// The property keys the names are read from.
    static func propertyKeys(language: String) -> Set<String> {
        ["name", "name:\(language)", "min_zoom", "sort_key", "population_rank", "elevation"]
    }

    struct Candidate: Equatable {
        let category: VectorTileLabelStyle.Category
        let name: String
        /// A second, smaller line: a summit's or a pass's height.
        let detail: String?
        /// Where the name belongs, in the picture's pixels.
        let anchor: CGPoint
        /// Order within a category, lower first.
        let rank: Double
    }

    struct Placement: Equatable {
        /// Which of the candidates this is.
        let index: Int
        /// The whole block, name and detail, in the picture's pixels.
        let frame: CGRect
    }

    // MARK: Choosing

    /// The names `tile` offers at `target`'s zoom whose points lie inside
    /// `bounds`, most important first. A point outside is another tile's to
    /// name, which is what keeps a name from being placed twice. A name the
    /// archive offers before its style's first zoom waits for that zoom: set
    /// at no size, Core Text would set it at its own.
    /// - Parameter height: a height in meters as the reader reads one.
    static func candidates(
        in tile: MapboxVectorTile,
        source: VectorTileAddress,
        target: VectorTileAddress,
        bounds: CGRect,
        language: String,
        height: (Double) -> String
    ) -> [Candidate] {
        var found: [Candidate] = []
        // A lake's name stands in `water`; a pond's often in `pois`, and in
        // `water` too a few zooms deeper.
        for layerName in ["places", "pois", "water"] {
            guard let layer = tile.layers[layerName] else { continue }
            let geometry = VectorTileGeometry(extent: layer.extent, source: source, target: target)
            for feature in layer.features where feature.type == .point {
                guard let category = category(of: feature, in: layerName),
                      VectorTileLabelStyle.look(of: category).size.value(at: target.z) > 0,
                      let name = name(of: feature, language: language),
                      Double(target.z) >= feature.number("min_zoom") ?? 0
                else { continue }
                let elevation = feature.number("elevation")
                let detail = category == .peak || category == .saddle ? elevation.map(height) : nil
                for point in geometry.points(of: feature) where bounds.contains(point) {
                    found.append(Candidate(
                        category: category,
                        name: name,
                        detail: detail,
                        anchor: point,
                        rank: rank(of: feature, category: category)
                    ))
                }
            }
        }
        var namedWater: Set<String> = []
        return found.sorted(by: precedes).filter { candidate in
            candidate.category != .water || namedWater.insert(candidate.name).inserted
        }
    }

    /// The name in `language`, or the local one.
    static func name(of feature: MapboxVectorTile.Feature, language: String) -> String? {
        let name = feature.string("name:\(language)") ?? feature.string("name")
        return name?.isEmpty == false ? name : nil
    }

    private static func category(
        of feature: MapboxVectorTile.Feature,
        in layerName: String
    ) -> VectorTileLabelStyle.Category? {
        let kind = feature.string("kind")
        let detail = feature.string("kind_detail")
        return switch layerName {
        case "places": .place(kind: kind, detail: detail)
        case "water": .water(kind: kind, detail: detail)
        default: .poi(kind: kind)
        }
    }

    /// Places by the archive's own `sort_key`, the larger place first; the
    /// higher summit or pass first; everything else by name.
    private static func rank(of feature: MapboxVectorTile.Feature, category: VectorTileLabelStyle.Category) -> Double {
        switch category {
        case .peak, .saddle: -(feature.number("elevation") ?? 0)
        case .hut, .water, .glacier: 0
        default: feature.number("sort_key") ?? -(feature.number("population_rank") ?? 0)
        }
    }

    private static func precedes(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
        if lhs.category != rhs.category { return lhs.category < rhs.category }
        if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
        if lhs.name != rhs.name { return lhs.name < rhs.name }
        if lhs.anchor.x != rhs.anchor.x { return lhs.anchor.x < rhs.anchor.x }
        return lhs.anchor.y < rhs.anchor.y
    }

    // MARK: Placing

    /// Each candidate, in order, at the first of its positions that fits
    /// inside `bounds` without touching a name already placed. A name with a
    /// symbol stands under it, or over it when under is taken; any other name
    /// is centred on its point. A position that crosses an edge is moved
    /// inward until it does not.
    /// - Parameters:
    ///   - sizes: each candidate's block, in pixels.
    ///   - spacing: the room kept between two names, and from each edge.
    ///   - markerClearance: how far a name stands from its symbol's centre.
    static func place(
        _ candidates: [Candidate],
        sizes: [CGSize],
        bounds: CGRect,
        spacing: CGFloat,
        markerClearance: CGFloat
    ) -> [Placement] {
        let inner = bounds.insetBy(dx: spacing, dy: spacing)
        var placed: [Placement] = []
        for (index, (candidate, size)) in zip(candidates, sizes).enumerated() {
            guard size.width <= inner.width, size.height <= inner.height else { continue }
            let anchor = candidate.anchor
            let left = anchor.x - size.width / 2
            let origins = candidate.category.hasMarker
                ? [
                    CGPoint(x: left, y: anchor.y + markerClearance),
                    CGPoint(x: left, y: anchor.y - markerClearance - size.height),
                ]
                : [CGPoint(x: left, y: anchor.y - size.height / 2)]
            for origin in origins {
                let frame = CGRect(
                    x: min(max(origin.x, inner.minX), inner.maxX - size.width),
                    y: min(max(origin.y, inner.minY), inner.maxY - size.height),
                    width: size.width,
                    height: size.height
                )
                let crowded = placed.contains { $0.frame.insetBy(dx: -spacing, dy: -spacing).intersects(frame) }
                if !crowded {
                    placed.append(Placement(index: index, frame: frame))
                    break
                }
            }
        }
        return placed
    }

    // MARK: Drawing

    /// The names placed on one tile, set in their fonts and ready to draw.
    struct Layout {
        private let blocks: [TextBlock]
        let placements: [Placement]

        /// `candidates` set at `z` and placed inside `bounds`, with `unit`
        /// pixels for each pixel of the style's 256-pixel tile.
        init(_ candidates: [Candidate], z: Int, unit: CGFloat, bounds: CGRect, language: String) {
            var fonts = LabelFonts(language: language)
            blocks = candidates.map { TextBlock($0, z: z, unit: unit, fonts: &fonts) }
            let markerClearance = (VectorTileStyle.peakSize.value(at: z) / 2 + VectorTileLabelStyle.markerGap) * unit
            placements = VectorTileLabels.place(
                candidates,
                sizes: blocks.map(\.size),
                bounds: bounds,
                spacing: VectorTileLabelStyle.spacing * unit,
                markerClearance: markerClearance
            )
        }

        /// Draws each placed name into `context`, whose y runs down.
        func draw(into context: CGContext) {
            context.saveGState()
            context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            context.setLineJoin(.round)
            for placement in placements {
                blocks[placement.index].draw(in: placement.frame, context: context)
            }
            context.restoreGState()
        }
    }
}

/// A name and its detail line, set in their font and measured.
nonisolated private struct TextBlock {
    let lines: [InkedText]

    var size: CGSize {
        CGSize(
            width: lines.map(\.width).max() ?? 0,
            height: lines.reduce(0) { $0 + $1.ascent + $1.descent }
        )
    }

    init(_ candidate: VectorTileLabels.Candidate, z: Int, unit: CGFloat, fonts: inout LabelFonts) {
        let look = VectorTileLabelStyle.look(of: candidate.category)
        let points = look.size.value(at: z) * unit
        let font = fonts.font(size: points, face: look.face)
        var set = [InkedText(candidate.name, font: font, color: look.color, unit: unit)]
        if let detail = candidate.detail {
            let detailFont = fonts.font(size: points * VectorTileLabelStyle.detailScale, face: look.face)
            set.append(InkedText(detail, font: detailFont, color: look.color, unit: unit))
        }
        lines = set
    }

    /// Each line centred in `frame`, its halo first.
    func draw(in frame: CGRect, context: CGContext) {
        var top = frame.minY
        for line in lines {
            let baseline = CGPoint(x: frame.midX - line.width / 2, y: top + line.ascent)
            line.drawHalo(at: baseline, context: context)
            line.drawInk(at: baseline, context: context)
            top += line.ascent + line.descent
        }
    }
}

/// Text set in a label's font and color, with the white halo drawn around
/// its letters, measured. Drawn into a context whose y runs down and whose
/// text matrix flips glyphs upright.
nonisolated struct InkedText {
    let ink: CTLine
    let halo: CTLine
    let width: CGFloat
    let ascent: CGFloat
    let descent: CGFloat

    init(_ text: String, font: CTFont, color: CGColor, unit: CGFloat) {
        let size = CTFontGetSize(font)
        let key = { (name: CFString) in NSAttributedString.Key(name as String) }
        ink = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            key(kCTFontAttributeName): font,
            key(kCTForegroundColorAttributeName): color,
        ]))
        // A positive stroke width strokes without filling. It is a share of
        // the font's size, and half of it lies outside the letters.
        let haloPercent = 2 * VectorTileLabelStyle.haloWidth * unit / max(size, 1) * 100
        halo = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            key(kCTFontAttributeName): font,
            key(kCTStrokeColorAttributeName): VectorTileLabelStyle.halo,
            key(kCTStrokeWidthAttributeName): haloPercent,
        ]))
        var rise: CGFloat = 0
        var fall: CGFloat = 0
        width = CGFloat(CTLineGetTypographicBounds(ink, &rise, &fall, nil))
        ascent = rise
        descent = fall
    }

    func drawHalo(at baseline: CGPoint, context: CGContext) {
        context.textPosition = baseline
        CTLineDraw(halo, context)
    }

    func drawInk(at baseline: CGPoint, context: CGContext) {
        context.textPosition = baseline
        CTLineDraw(ink, context)
    }
}

/// The fonts one tile's names are set in, each made once. Making the system
/// font at a size is most of what setting a name costs, and a name along a
/// line is set a letter at a time.
nonisolated struct LabelFonts {
    let language: String
    private var made: [Key: CTFont] = [:]

    init(language: String) {
        self.language = language
    }

    mutating func font(size: CGFloat, face: VectorTileLabelStyle.Face) -> CTFont {
        let key = Key(size: size, face: face)
        if let font = made[key] { return font }
        let font = VectorTileLabelStyle.font(size: size, face: face, language: language)
        made[key] = font
        return font
    }

    private struct Key: Hashable {
        let size: CGFloat
        let face: VectorTileLabelStyle.Face
    }
}
