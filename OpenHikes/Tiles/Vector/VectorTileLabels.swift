//
//  VectorTileLabels.swift
//  OpenHikes
//
//  The names of places, lakes and glaciers on a drawn tile. Each is in the
//  app's language where the map has the name in it, and in the local one
//  where it does not, which for a hamlet is always. Summits, huts and every
//  other point are drawn with their icons, in ``VectorTilePoints``.
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
        /// Where the name belongs, in the picture's pixels.
        let anchor: CGPoint
        /// Order within a category, lower first.
        let rank: Double
    }

    struct Placement: Equatable {
        /// Which of the candidates this is.
        let index: Int
        /// The name, in the picture's pixels.
        let frame: CGRect
    }

    // MARK: Choosing

    /// The names `tile` offers at `target`'s zoom whose points lie inside
    /// `bounds`, most important first. A point outside is another tile's to
    /// name, which is what keeps a name from being placed twice. A name the
    /// archive offers before its style's first zoom waits for that zoom: set
    /// at no size, Core Text would set it at its own.
    static func candidates(
        in tile: MapboxVectorTile,
        source: VectorTileAddress,
        target: VectorTileAddress,
        bounds: CGRect,
        language: String
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
                for point in geometry.points(of: feature) where bounds.contains(point) {
                    found.append(Candidate(
                        category: category,
                        name: name,
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

    /// Places by the archive's own `sort_key`, the larger place first;
    /// water and ice by name.
    private static func rank(of feature: MapboxVectorTile.Feature, category: VectorTileLabelStyle.Category) -> Double {
        switch category {
        case .water, .glacier: 0
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

    /// Each candidate, in order, centred on its point where that fits inside
    /// `bounds` without touching a name already placed. A name that crosses
    /// an edge is moved inward until it does not.
    /// - Parameters:
    ///   - sizes: each candidate's name, in pixels.
    ///   - spacing: the room kept between two names, and from each edge.
    static func place(
        _ candidates: [Candidate],
        sizes: [CGSize],
        bounds: CGRect,
        spacing: CGFloat
    ) -> [Placement] {
        let inner = bounds.insetBy(dx: spacing, dy: spacing)
        var placed: [Placement] = []
        for (index, (candidate, size)) in zip(candidates, sizes).enumerated() {
            guard size.width <= inner.width, size.height <= inner.height else { continue }
            let frame = CGRect(
                x: min(max(candidate.anchor.x - size.width / 2, inner.minX), inner.maxX - size.width),
                y: min(max(candidate.anchor.y - size.height / 2, inner.minY), inner.maxY - size.height),
                width: size.width,
                height: size.height
            )
            let crowded = placed.contains { $0.frame.insetBy(dx: -spacing, dy: -spacing).intersects(frame) }
            if !crowded { placed.append(Placement(index: index, frame: frame)) }
        }
        return placed
    }

    // MARK: Drawing

    /// The names placed on one tile, set in their fonts and ready to draw.
    struct Layout {
        private let blocks: [InkedText]
        let placements: [Placement]

        /// `candidates` set at `z` and placed inside `bounds`, with `unit`
        /// pixels for each pixel of the style's 256-pixel tile.
        init(_ candidates: [Candidate], z: Int, unit: CGFloat, bounds: CGRect, language: String) {
            var fonts = LabelFonts(language: language)
            blocks = candidates.map { candidate in
                let look = VectorTileLabelStyle.look(of: candidate.category)
                let font = fonts.font(size: look.size.value(at: z) * unit, face: look.face)
                return InkedText(candidate.name, font: font, color: look.color, unit: unit)
            }
            placements = VectorTileLabels.place(
                candidates,
                sizes: blocks.map { CGSize(width: $0.width, height: $0.ascent + $0.descent) },
                bounds: bounds,
                spacing: VectorTileLabelStyle.spacing * unit
            )
        }

        /// Draws each placed name into `context`, whose y runs down.
        func draw(into context: CGContext) {
            context.saveGState()
            context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            context.setLineJoin(.round)
            for placement in placements {
                let name = blocks[placement.index]
                let baseline = CGPoint(x: placement.frame.minX, y: placement.frame.minY + name.ascent)
                name.drawHalo(at: baseline, context: context)
                name.drawInk(at: baseline, context: context)
            }
            context.restoreGState()
        }
    }
}

/// Text set in a label's font and color, with a halo drawn around its
/// letters, measured. Drawn into a context whose y runs down and whose
/// text matrix flips glyphs upright.
nonisolated struct InkedText {
    let ink: CTLine
    let halo: CTLine
    let width: CGFloat
    let ascent: CGFloat
    let descent: CGFloat

    /// - Parameter haloWidth: how far the halo reaches past the letters, in
    ///   the pixels of the style's 256-pixel tile.
    init(
        _ text: String,
        font: CTFont,
        color: CGColor,
        unit: CGFloat,
        halo haloColor: CGColor = VectorTileLabelStyle.halo,
        haloWidth: CGFloat = VectorTileLabelStyle.haloWidth
    ) {
        let size = CTFontGetSize(font)
        let key = { (name: CFString) in NSAttributedString.Key(name as String) }
        ink = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            key(kCTFontAttributeName): font,
            key(kCTForegroundColorAttributeName): color,
        ]))
        // A positive stroke width strokes without filling. It is a share of
        // the font's size, and half of it lies outside the letters.
        let haloPercent = 2 * haloWidth * unit / max(size, 1) * 100
        halo = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            key(kCTFontAttributeName): font,
            key(kCTStrokeColorAttributeName): haloColor,
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
