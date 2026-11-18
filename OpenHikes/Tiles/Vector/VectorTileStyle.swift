//
//  VectorTileStyle.swift
//  OpenHikes
//
//  What the map draws each kind of thing in the Protomaps basemap as: a fill,
//  a stroke, a width at each zoom. The kinds are Protomaps' (`kind` and
//  `kind_detail` on each feature); the colors are OpenStreetMap Carto's, the
//  style tile.openstreetmap.org draws and which is CC0, so the map a hiker
//  knows from the raster tiles keeps its look.
//
//  Widths are in the pixels of a 256-pixel tile, the unit every tile source's
//  figures are quoted in; ``VectorTileRasterizer`` scales them to the size it
//  draws at.
//
//  Names are drawn over all of this, in ``VectorTileLabelStyle``'s looks.
//

import CoreGraphics

nonisolated enum VectorTileStyle {
    static let ocean = color("#AAD3DF")
    static let land = color("#F2EFE9")
    static let water = color("#AAD3DF")
    static let building = color("#D9D0C9")
    static let buildingOutline = color("#C4B6AB")
    static let cliff = color("#999999")
    static let protectedArea = color("#008000", alpha: protectedAreaAlpha)

    /// Buildings are drawn from this zoom, and outlined from ``outlinedBuildingZ``.
    static let buildingZ = 13
    static let outlinedBuildingZ = 15
    /// Landcover is the archive's low-zoom picture of the ground; landuse
    /// takes over above it.
    static let deepestLandcoverZ = 7
    static let cliffZ = 13
    /// The zooms past 16 that OpenStreetMap Carto changes a size at.
    static let z17 = 17
    static let z18 = 18
    static let z19 = 19

    static let landcoverFills = fills([
        (["forest"], "#ADD19E"),
        (["grassland"], "#CDEBB0"),
        (["farmland"], "#EEF0D5"),
        (["scrub"], "#C8D7AB"),
        (["glacier"], "#DDECEC"),
        (["barren"], "#EEE5DC"),
        (["urban_area"], "#E0DFDF"),
    ])

    static let landuseFills = fills([
        (["forest", "wood"], "#ADD19E"),
        (["park", "village_green", "dog_park"], "#C8FACC"),
        (["grass", "meadow", "grassland", "recreation_ground", "garden"], "#CDEBB0"),
        (["scrub", "heath"], "#C8D7AB"),
        (["farmland"], "#EEF0D5"),
        (["orchard", "vineyard"], "#AEDFA3"),
        (["allotments"], "#C9E1BF"),
        (["residential"], "#E0DFDF"),
        (["commercial"], "#F2DAD9"),
        (["retail"], "#FFD6D1"),
        (["industrial", "railway"], "#EBDBE8"),
        (["cemetery", "grave_yard"], "#AACBAF"),
        (["hospital", "school", "university", "college", "kindergarten"], "#FFFFE5"),
        (["pitch"], "#AAE0CB"),
        (["playground", "stadium", "sports_centre"], "#DFFCE2"), // swiftlint:disable:this american_spelling_in_copy
        (["golf_course"], "#DEF6C0"),
        (["pedestrian", "platform"], "#DDDDE8"),
        (["parking"], "#EEEEEE"),
        (["aerodrome"], "#E9E7E2"),
        (["military"], "#F3E3DD"),
        (["beach"], "#FFF1BA"),
        (["sand"], "#F5E9C6"),
        (["bare_rock", "scree"], "#EEE5DC"),
        (["glacier"], "#DDECEC"),
        (["wetland", "marsh", "swamp", "bog"], "#DDE8D3"),
        (["quarry", "landfill", "brownfield"], "#C5C3C3"),
    ])

    /// Kinds drawn as a border rather than a fill: they cover whole valleys,
    /// and a fill would hide the ground they are drawn over.
    static let protectedAreaKinds: Set<String> = ["national_park", "nature_reserve", "protected_area"]
    static let protectedAreaWidth = ZoomCurve([(8, 0.75), (12, 1), (16, 2)])

    static let waterLineWidths: [String: ZoomCurve] = {
        let river = ZoomCurve([(10, 0.75), (12, 1), (14, 3), (16, 6), (20, 24)])
        let stream = ZoomCurve([(12, 0.5), (14, 1), (16, 2), (20, 4)])
        return ["river": river, "canal": river, "stream": stream, "drain": stream, "ditch": stream]
    }()

    static let cliffWidth = ZoomCurve([(13, 0.5), (16, 1), (20, 2)])

    // MARK: Lines

    struct Line: Sendable {
        let color: CGColor
        let width: ZoomCurve
        /// Drawn under ``color``, wider by ``VectorTileStyle/casingWidth`` on
        /// each side.
        var casing: CGColor?
        /// Dash and gap lengths as multiples of the line's width, so a dash
        /// keeps its shape as the line widens with zoom. Empty for solid.
        var dash: [CGFloat] = []
        var alpha: CGFloat = 1
        /// Drawn down the middle of the line, straight after it: a railway's
        /// white dashes.
        var center: Center?
    }

    /// A narrower line drawn down the middle of another.
    struct Center: Sendable {
        let color: CGColor
        let width: ZoomCurve
        /// As ``Line/dash``: multiples of the center's own width.
        var dash: [CGFloat] = []
    }

    /// Each side of a road's casing, which separates a road from the ground
    /// and from the road beside it. None below zoom 12, where a road is
    /// narrower than its casing would be.
    static let casingWidth = ZoomCurve([(12, 0.5), (14, 0.75), (16, 1), (20, 2)])

    /// A road's look, and its place among the roads of its level: a road
    /// with a higher ``order`` is drawn over one with a lower.
    struct Road: Sendable {
        let line: Line
        let order: Int
    }

    /// The style of a feature in the `roads` layer, or `nil` for one not drawn:
    /// its `kind` and `kind_detail` first, then its `kind` alone.
    static func road(kind: String, detail: String?) -> Road? {
        roads["\(kind)/\(detail ?? "")"] ?? roads["\(kind)/*"]
    }

    /// Keyed `kind/kind_detail`, with `kind/*` for every detail not listed,
    /// and listed in the order they are drawn: OpenStreetMap Carto's
    /// `z_order`, so the more important road's surface runs through a
    /// junction. The archive cannot say this: it gives every road the same
    /// `sort_rank`.
    ///
    /// Links come under every street, as Carto has them, and railways and
    /// aerial ways over the roads they cross. The archive files a highway
    /// it has no kind for as `other`, with the highway as its detail: of
    /// those only the living street, a street people walk down, is drawn.
    private static let roads: [String: Road] = Dictionary(
        uniqueKeysWithValues: [
            ("ferry/*", ferry),
            ("path/steps", steps),
            ("path/*", footpath),
            ("path/cycleway", cycleway),
            ("path/bridleway", bridleway),
            ("path/track", track),
            ("minor_road/service", service),
            ("major_road/tertiary_link", tertiary),
            ("major_road/secondary_link", secondary),
            ("major_road/primary_link", primary),
            ("major_road/trunk_link", trunk),
            ("highway/motorway_link", motorway),
            ("path/pedestrian", pedestrian),
            ("other/living_street", livingStreet),
            ("minor_road/*", minorRoad),
            ("major_road/*", tertiary),
            ("major_road/secondary", secondary),
            ("major_road/primary", primary),
            ("major_road/trunk", trunk),
            ("highway/*", motorway),
            ("rail/subway", subway),
            ("rail/disused", disusedRailway),
            ("rail/tram", tram),
            ("rail/*", railway),
            ("aerialway/*", aerialway),
        ].enumerated().map { order, entry in (entry.0, Road(line: entry.1, order: order)) }
    )

    /// The style of a feature in the vector extras' `barriers` layer, as
    /// Carto draws it: a thin dark line from zoom 16 for a fence, a wall or a
    /// guard rail, a hedge in the woods' green, and a city wall wider and
    /// paler from zoom 15.
    static func barrier(kind: String?) -> Line {
        switch kind {
        case "hedge": hedge
        case "city_wall": cityWall
        default: barrierLine
        }
    }

    /// The style of a feature in the `boundaries` layer, or `nil` for one
    /// not drawn. A disputed line is dotted whatever its level.
    static func boundary(kind: String, disputed: Bool) -> Line? {
        guard var line = boundaries[kind] else { return nil }
        if disputed { line.dash = [2, 2] }
        return line
    }

    private static let boundaries: [String: Line] = [
        "country": country,
        "region": region,
        "county": localBoundary,
        "locality": localBoundary,
    ]

    private static let protectedAreaAlpha: CGFloat = 0.35

    /// The color a `#RRGGBB` names, as the hiking-routes layer writes one.
    static func color(_ hex: String, alpha: CGFloat = 1) -> CGColor {
        let opaque = HikingRoutesStyle.color(hex)
        return alpha < 1 ? opaque.copy(alpha: alpha) ?? opaque : opaque
    }

    private static func fills(_ entries: [(kinds: [String], hex: String)]) -> [String: CGColor] {
        var fills: [String: CGColor] = [:]
        for entry in entries {
            for kind in entry.kinds { fills[kind] = color(entry.hex) }
        }
        return fills
    }
}

// MARK: - The figures

nonisolated private extension VectorTileStyle {
    static let motorway = Line(
        color: color("#E892A2"),
        width: ZoomCurve([(5, 0.5), (8, 1), (10, 2), (12, 3), (14, 6), (16, 12), (20, 48)]),
        casing: color("#DC2A67")
    )
    static let trunk = Line(
        color: color("#F9B29C"),
        width: ZoomCurve([(6, 0.5), (9, 1), (11, 2), (12, 3), (14, 5), (16, 10), (20, 40)]),
        casing: color("#C84E2F")
    )
    static let primary = Line(
        color: color("#FCD6A4"),
        width: ZoomCurve([(8, 0.5), (10, 1), (12, 2), (14, 5), (16, 9), (20, 36)]),
        casing: color("#A06B00")
    )
    static let secondary = Line(
        color: color("#F7FABF"),
        width: ZoomCurve([(9, 0.5), (11, 1), (12, 2), (14, 4), (16, 8), (20, 32)]),
        casing: color("#707D05")
    )
    /// Tertiary and every other major road.
    static let tertiary = Line(
        color: color("#FFFFFF"),
        width: ZoomCurve([(10, 0.5), (12, 1), (14, 4), (16, 7), (20, 25)]),
        casing: color("#8F8F8F")
    )
    static let service = Line(
        color: color("#FFFFFF"),
        width: ZoomCurve([(13, 0.5), (14, 1), (16, 3), (20, 12)]),
        casing: color("#BBBBBB")
    )
    static let minorRoad = Line(
        color: color("#FFFFFF"),
        width: ZoomCurve([(12, 0.5), (13, 1), (14, 2), (16, 6), (20, 24)]),
        casing: color("#BBBBBB")
    )
    /// A minor road in Carto's paler gray.
    static let livingStreet = Line(
        color: color("#EDEDED"),
        width: ZoomCurve([(12, 0.5), (13, 1), (14, 2), (16, 6), (20, 24)]),
        casing: color("#BBBBBB")
    )
    static let track = Line(
        color: color("#996600"),
        width: ZoomCurve([(12, 0.5), (14, 1), (16, 2), (20, 3)]),
        dash: [5, 3]
    )
    static let steps = Line(
        color: color("#FA8072"),
        width: ZoomCurve([(13, 1), (15, 2), (20, 4)]),
        dash: [1, 1]
    )
    static let cycleway = Line(
        color: color("#0000FF"),
        width: ZoomCurve([(13, 0.5), (15, 1), (20, 2)]),
        dash: [1, 3]
    )
    static let bridleway = Line(
        color: color("#008000"),
        width: ZoomCurve([(13, 0.5), (15, 1), (20, 2)]),
        dash: [4, 2]
    )
    static let pedestrian = Line(
        color: color("#DDDDE8"),
        width: ZoomCurve([(13, 1), (14, 2), (16, 6), (20, 24)]),
        casing: color("#999999")
    )
    /// Footways, paths and every path kind not listed: what a hiker walks.
    static let footpath = Line(
        color: color("#FA8072"),
        width: ZoomCurve([(12, 0.5), (14, 0.75), (16, 1), (20, 2)]),
        dash: [2, 3]
    )
    static let subway = Line(color: color("#999999"), width: ZoomCurve([(12, 0.5), (16, 1)]), alpha: 0.5)
    /// Carto's railway: a gray line with white dashes down it from zoom 12,
    /// a thin gray one before.
    static let railway = Line(
        color: color("#707070"),
        width: ZoomCurve([(10, 0.5), (11, 1), (12, 2), (13, 3), (z17, 3), (z18, 4)]),
        center: Center(
            color: color("#FFFFFF"),
            width: ZoomCurve([(12, 0.75), (13, 1), (z17, 1), (z18, 2)]),
            dash: [8, 8]
        )
    )
    static let tram = Line(color: color("#6E6E6E"), width: ZoomCurve([(12, 0.75), (14, 1), (z17, 2)]))
    /// Carto draws an unused line light and broken, and only up close.
    static let disusedRailway = Line(color: color("#AAAAAA"), width: ZoomCurve([(15, 2)]), dash: [1, 2])
    static let ferry = Line(color: color("#6666FF"), width: ZoomCurve([(8, 0.5), (12, 1), (16, 2)]), dash: [6, 4])
    static let aerialway = Line(color: color("#808080"), width: ZoomCurve([(12, 0.5), (15, 1), (20, 2)]))

    static let barrierInk = color("#444444")
    static let barrierWidth: CGFloat = 0.4
    static let barrierLine = Line(color: barrierInk, width: ZoomCurve([(16, barrierWidth)]))
    static let hedgeNarrowest: CGFloat = 1.5
    static let hedge = Line(
        color: color("#ADD19E"),
        width: ZoomCurve([(16, hedgeNarrowest), (z17, 2), (z18, 3), (z19, 4), (20, 5)])
    )
    /// Carto's `lighten(#444, 30%)`, with the dark line down it from zoom 17.
    static let cityWall = Line(
        color: color("#919191"),
        width: ZoomCurve([(15, 1), (16, hedgeNarrowest), (z17, 2), (z18, 3), (z19, 4)]),
        center: Center(color: barrierInk, width: ZoomCurve([(z17, barrierWidth)]))
    )

    static let boundaryPurple = color("#8D618B")
    static let country = Line(color: boundaryPurple, width: ZoomCurve([(2, 0.5), (5, 1), (12, 2), (16, 4)]), alpha: 0.5)
    static let region = Line(
        color: boundaryPurple,
        width: ZoomCurve([(5, 0.25), (8, 0.75), (12, 1), (16, 2)]),
        dash: [3, 2],
        alpha: 0.5
    )
    static let localBoundary = Line(
        color: boundaryPurple,
        width: ZoomCurve([(10, 0.5), (14, 0.75)]),
        dash: [2, 2],
        alpha: 0.25
    )
}

/// A size given at a few zooms: none below the first, each zoom between two
/// stops in proportion on a doubling scale, and the last stop's past it.
nonisolated struct ZoomCurve: Sendable {
    private let stops: [(z: Int, value: CGFloat)]

    init(_ stops: [(z: Int, value: CGFloat)]) {
        self.stops = stops
    }

    /// The size at `z`, or zero below the first stop.
    func value(at z: Int) -> CGFloat {
        guard let first = stops.first, let last = stops.last, z >= first.z else { return 0 }
        guard z < last.z else { return last.value }
        guard let upper = stops.firstIndex(where: { $0.z > z }), upper > 0 else { return first.value }
        let low = stops[upper - 1]
        let high = stops[upper]
        let fraction = CGFloat(z - low.z) / CGFloat(high.z - low.z)
        return low.value * pow(high.value / low.value, fraction)
    }
}
