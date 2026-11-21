//
//  VectorTilePatterns.swift
//  OpenHikesVectorTiles
//
//  The pictures OpenStreetMap Carto fills an area with — a wood's trees by
//  their leaves, a wetland's reeds, scree, a quarry's hammers, the red hatch
//  over a firing range — and the dots it lays along a ridge. The pictures are
//  Carto's own (CC0), copied into `CartoIcons.xcassets` by
//  `Scripts/carto-points.sh` under `carto-pattern-` and the name Carto's style
//  calls each by.
//
//  A pattern is laid from the corner of the world, as Carto lays one
//  (`polygon-pattern-alignment: global`), and a tile draws the part of it
//  that falls on its own ground: a wood across two tiles has whole trees
//  along their shared edge, with neither tile having seen the other.
//
//  Carto draws a pattern at one of two moments. Most go straight over the
//  fill of the area they belong to (`landcover.mss`), so a smaller area drawn
//  after it covers them: ``ground(kind:detail:z:)``. The woods, wetlands,
//  beaches, scrub and reefs go on after all the ground and the water
//  (`landcover-area-symbols`), over whatever lies inside them:
//  ``symbols(kind:detail:z:)``.
//
//  What picks a wood's trees or a wetland's reeds is a tag the basemap drops,
//  which the vector extras bring back as the area's `kind_detail`
//  (``VectorTileAreaDetails``). Without it a wood has the trees Carto gives
//  one whose leaves nobody mapped.
//

import CoreGraphics

enum VectorTilePatterns {
    /// One of Carto's pictures, and how strongly it is drawn.
    struct Pattern: Equatable, Sendable {
        /// The picture in `CartoIcons.xcassets`.
        let asset: String
        let opacity: CGFloat

        /// - Parameter name: the picture's file in Carto, less its type.
        init(_ name: String, opacity: CGFloat = 1) {
            asset = VectorTilePatterns.assetPrefix + name
            self.opacity = opacity
        }

        /// The same picture at full strength, for drawing into a layer
        /// that is itself faded.
        var solid: Self { Self(String(asset.dropFirst(VectorTilePatterns.assetPrefix.count))) }
    }

    static let assetPrefix = "carto-pattern-"

    /// Carto draws most patterns from this zoom, a quarry's, a wetland's
    /// plain marks and a reef's from ``wideZ``, and a dog park's paws from
    /// ``dogParkZ``.
    static let firstZ = 13
    static let wideZ = 10
    static let dogParkZ = 16

    // MARK: Which pattern

    /// The pattern drawn straight over the fill of an area of `kind` in the
    /// `landuse` layer at zoom `z`, or `nil` for an area with none there.
    /// - Parameter detail: a cemetery's religion.
    static func ground(kind: String, detail: String?, z: Int) -> Pattern? {
        if cemeteries.contains(kind) {
            guard z >= firstZ else { return nil }
            return Pattern("grave_yard_" + (detail.flatMap { religions.contains($0) ? $0 : nil } ?? "generic"))
        }
        guard let entry = overFill[kind], z >= entry.z else { return nil }
        return Pattern(entry.name, opacity: entry.opacity)
    }

    /// The symbols drawn over an area of `kind` after the ground and the
    /// water, at zoom `z`, or `nil` for an area with none there.
    /// - Parameter detail: a wood's `leaf_type`, a wetland's `wetland` or a
    ///   beach's `surface`.
    static func symbols(kind: String, detail: String?, z: Int) -> Pattern? {
        switch kind {
        case "wood", "forest":
            guard z >= firstZ else { return nil }
            let leaf = detail.flatMap { leaves.contains($0) ? $0 : nil } ?? "unknown"
            return Pattern("leaftype_" + leaf, opacity: woodOpacity)
        case "wetland", "mud":
            guard z >= wideZ else { return nil }
            return Pattern(z >= firstZ ? detail.flatMap { wetlands[$0] } ?? "wetland" : "wetland")
        case "beach", "shoal":
            guard z >= firstZ, let name = detail.flatMap({ surfaces[$0] }) else { return nil }
            return Pattern(name)
        case "reef":
            return z >= wideZ ? Pattern("reef") : nil
        case "scrub", "salt_pond":
            return z >= firstZ ? Pattern(kind) : nil
        default:
            return nil
        }
    }

    /// The red hatch Carto lays over military land and over a danger area,
    /// with everything else it draws there (``VectorTileStyle/restricted(kind:)``).
    static func hatch(kind: String) -> Pattern {
        Pattern(kind == "danger_area" ? "danger_red_hatch" : "military_red_hatch")
    }

    /// The lines Carto draws over water that is not always there, in the
    /// place of its fill.
    static let intermittentWater = Pattern("intermittent_water")

    /// The dots along a ridge or an arête at zoom `z`: closer and darker
    /// from zoom 15.
    static func ridge(kind: String?, z: Int) -> Pattern {
        let name = kind == "arete" ? "arete" : "ridge"
        return Pattern(z >= deepRidgeZ ? name + "2" : name + "-mid")
    }

    private static let deepRidgeZ = 15
    /// Carto draws a wood's trees as one layer at this strength, so two
    /// woods mapped over each other show the trees once.
    static let woodOpacity: CGFloat = 0.4
    private static let gardenOpacity: CGFloat = 0.6

    private static let cemeteries: Set<String> = ["cemetery", "grave_yard"]
    private static let religions: Set<String> = ["christian", "jewish", "muslim"]
    private static let leaves: Set<String> = ["broadleaved", "needleleaved", "mixed", "leafless"]

    private static let overFill: [String: (name: String, z: Int, opacity: CGFloat)] = [
        "quarry": ("quarry", wideZ, 1),
        "vineyard": ("vineyard", firstZ, 1),
        "orchard": ("orchard", firstZ, 1),
        "plant_nursery": ("plant_nursery", firstZ, 1),
        "garden": ("plant_nursery", firstZ, gardenOpacity),
        "allotments": ("allotments", firstZ, 1),
        "dog_park": ("dog_park", dogParkZ, 1),
        "bare_rock": ("rock_overlay", firstZ, 1),
        "scree": ("scree_overlay", firstZ, 1),
        "shingle": ("scree_overlay", firstZ, 1),
    ]

    private static let wetlands: [String: String] = [
        "marsh": "wetland_marsh", "saltmarsh": "wetland_marsh", "wet_meadow": "wetland_marsh",
        "reedbed": "wetland_reed",
        "mangrove": "wetland_mangrove",
        "swamp": "wetland_swamp",
        "bog": "wetland_bog", "fen": "wetland_bog", "string_bog": "wetland_bog",
    ]

    private static let surfaces: [String: String] = [
        "sand": "beach",
        "gravel": "beach_coarse", "fine_gravel": "beach_coarse", "pebbles": "beach_coarse",
        "pebblestone": "beach_coarse", "shingle": "beach_coarse", "stones": "beach_coarse", "shells": "beach_coarse",
    ]

    // MARK: Drawing

    /// `image` laid over the whole picture of the tile at `target`, from the
    /// corner of the world, in the pixels it has: whatever clip the context
    /// holds decides where it shows.
    static func lay(_ image: CGImage, in context: CGContext, target: VectorTileAddress) {
        let side = CGFloat(VectorTileRasterizer.pixelSize)
        let size = CGSize(width: image.width, height: image.height)
        guard size.width > 0, size.height > 0 else { return }
        // How far into a copy of the picture the tile's own corner falls.
        let left = (CGFloat(target.x) * side).truncatingRemainder(dividingBy: size.width)
        let top = (CGFloat(target.y) * side).truncatingRemainder(dividingBy: size.height)
        context.saveGState()
        // The picture's rows run up; the tile's down.
        context.translateBy(x: 0, y: side)
        context.scaleBy(x: 1, y: -1)
        context.draw(
            image,
            in: CGRect(x: -left, y: side + top - size.height, width: size.width, height: size.height),
            byTiling: true
        )
        context.restoreGState()
    }

    /// `image` laid end to end along `line`, its middle on the line and each
    /// copy turned the way the line runs under it, as Mapnik lays a line's
    /// pattern; the last copy is cut where the line ends.
    static func lay(_ image: CGImage, along line: [CGPoint], in context: CGContext) {
        let path = MeasuredPath(line)
        let size = CGSize(width: image.width, height: image.height)
        guard size.width > 0, path.length > 0 else { return }
        for start in stride(from: 0, to: path.length, by: size.width) {
            let run = min(size.width, path.length - start)
            let from = path.point(at: start)
            let to = path.point(at: start + run)
            context.saveGState()
            context.translateBy(x: from.x, y: from.y)
            context.rotate(by: atan2(to.y - from.y, to.x - from.x))
            context.clip(to: CGRect(x: 0, y: -size.height / 2, width: run, height: size.height))
            // The picture's rows run up; the tile's down.
            context.translateBy(x: 0, y: size.height / 2)
            context.scaleBy(x: 1, y: -1)
            context.draw(image, in: CGRect(origin: .zero, size: size))
            context.restoreGState()
        }
    }

    // MARK: Teeth

    /// A cliff's or an embankment's line as Carto draws one (`cliff.svg`,
    /// `cliff2.svg`, `embankment.svg`): a thin line with a tooth every so
    /// often on the side that falls away, which is the right of the way the
    /// line was mapped. Sizes are in the pixels of a 256-pixel tile.
    struct Teeth: Equatable, Sendable {
        let color: CGColor
        /// From one tooth to the next.
        let spacing: CGFloat
        /// A tooth's width where it leaves the line, and at its end.
        let base: CGFloat
        let tip: CGFloat
        let height: CGFloat
    }

    /// Carto draws a cliff from this zoom and an embankment from
    /// ``embankmentZ``.
    static let cliffZ = 13
    static let embankmentZ = 15

    /// The line of a feature in the extras' `cliffs` layer at zoom `z`, or
    /// `nil` where Carto draws none.
    static func teeth(kind: String?, z: Int) -> Teeth? {
        if kind == "embankment" { return z >= embankmentZ ? embankment : nil }
        guard z >= cliffZ else { return nil }
        return z >= deepCliffZ ? deepCliff : cliff
    }

    /// The width of the line the teeth stand on.
    static let teethLineWidth: CGFloat = 1

    /// `teeth` along `line`, in a picture `unit` pixels to each of the
    /// style's: the line, then each tooth where the line has room for the
    /// whole of it, standing square to the line under it.
    static func draw(_ teeth: Teeth, along line: [CGPoint], in context: CGContext, unit: CGFloat) {
        let path = MeasuredPath(line)
        guard line.count > 1, path.length > 0 else { return }
        context.saveGState()
        context.setStrokeColor(teeth.color)
        context.setFillColor(teeth.color)
        context.setLineWidth(teethLineWidth * unit)
        context.setLineJoin(.miter)
        context.setLineCap(.butt)
        context.addLines(between: line)
        context.strokePath()
        let half = teeth.base * unit / 2
        let root = teethLineWidth * unit / 2
        for middle in stride(from: teeth.spacing * unit / 2, through: path.length - half, by: teeth.spacing * unit) {
            let from = path.point(at: middle - half)
            let to = path.point(at: middle + half)
            let run = hypot(to.x - from.x, to.y - from.y)
            guard run > 0 else { continue }
            let along = CGVector(dx: (to.x - from.x) / run, dy: (to.y - from.y) / run)
            // To the right of the way the line runs, on a picture whose y
            // runs down.
            let down = CGVector(dx: -along.dy, dy: along.dx)
            let center = path.point(at: middle)
            let corner = { (across: CGFloat, out: CGFloat) -> CGPoint in
                let x: CGFloat = center.x + along.dx * across + down.dx * out
                let y: CGFloat = center.y + along.dy * across + down.dy * out
                return CGPoint(x: x, y: y)
            }
            let end: CGFloat = root + teeth.height * unit
            let tip: CGFloat = teeth.tip * unit / 2
            context.addLines(between: [corner(-half, root), corner(-tip, end), corner(tip, end), corner(half, root)])
            context.fillPath()
        }
        context.restoreGState()
    }

    private static let deepCliffZ = 15
    private static let cliffGray = VectorTileStyle.color("#999999")
    private static let cliffSpacing: CGFloat = 15
    private static let cliff = Teeth(color: cliffGray, spacing: cliffSpacing, base: 3, tip: 1, height: 3)
    private static let deepCliff = Teeth(color: cliffGray, spacing: cliffSpacing, base: 5, tip: 1, height: 5)
    private static let embankmentTip: CGFloat = 1.5
    private static let embankment = Teeth(
        color: VectorTileStyle.color("#7B7B7B"),
        spacing: 12,
        base: 2,
        tip: embankmentTip,
        height: 2
    )
}
