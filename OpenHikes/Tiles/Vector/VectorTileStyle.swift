//
//  VectorTileStyle.swift
//  OpenHikes
//
//  What the map draws each kind of thing in the Protomaps basemap and the
//  vector extras as: a fill, a stroke, a width at each zoom. The kinds are
//  Protomaps' (`kind` and `kind_detail` on each feature), and the extras name
//  theirs the same way; the colors are OpenStreetMap Carto's, the style
//  tile.openstreetmap.org draws and which is CC0, so the map a hiker knows
//  from the raster tiles keeps its look.
//
//  Widths are in the pixels of a 256-pixel tile, the unit every tile source's
//  figures are quoted in; ``VectorTileRasterizer`` scales them to the size it
//  draws at.
//
//  The ground, the water and the lines that are not roads are here; the roads,
//  railways and lifts are in `VectorTileRoadStyle.swift`. Names are drawn over
//  all of it, in ``VectorTileLabelStyle``'s looks.
//

import CoreGraphics

nonisolated enum VectorTileStyle {
    static let ocean = color("#AAD3DF")
    static let land = color("#F2EFE9")
    static let water = color("#AAD3DF")
    static let building = color("#D9D0C9")
    static let buildingOutline = color("#C4B6AB")
    static let cliff = color("#999999")
    static let park = color("#C8FACC")
    static let dam = color("#ADADAD")

    /// Buildings are drawn from this zoom, and outlined from ``outlinedBuildingZ``.
    static let buildingZ = 13
    static let outlinedBuildingZ = 15
    /// The archive's kind for a part of a building, which Carto does not
    /// draw: the building it is part of is drawn whole.
    static let buildingPartKind = "building_part"
    /// Landcover is the archive's low-zoom picture of the ground; landuse
    /// takes over above it.
    static let deepestLandcoverZ = 7
    static let cliffZ = 13
    /// Carto fills a park from this zoom, and a dam from ``damZ``.
    static let parkZ = 10
    static let damZ = 13
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

    /// The fill of each kind in the `landuse` layer. A park is not among
    /// them: the basemap files most national parks as one, so the parks
    /// filled are the vector extras' own (``park``), and a kind the basemap
    /// never sends is the extras'.
    static let landuseFills = fills([
        (["forest", "wood"], "#ADD19E"),
        (["village_green", "dog_park"], "#C8FACC"),
        (["grass", "meadow", "grassland", "recreation_ground", "garden"], "#CDEBB0"),
        (["scrub"], "#C8D7AB"),
        (["heath"], "#D6D99F"),
        (["farmland", "greenhouse_horticulture"], "#EEF0D5"),
        (["farmyard"], "#F5DCBA"),
        (["orchard", "vineyard", "plant_nursery"], "#AEDFA3"),
        (["allotments"], "#C9E1BF"),
        (["residential"], "#E0DFDF"),
        (["commercial"], "#F2DAD9"),
        (["retail"], "#FFD6D1"),
        (["industrial", "railway", "works", "wastewater_plant", "water_works"], "#EBDBE8"),
        (["power"], "#E3CBDF"),
        (["cemetery", "grave_yard"], "#AACBAF"),
        (["hospital", "school", "university", "college", "kindergarten"], "#FFFFE5"),
        (["pitch", "track"], "#88E0BE"),
        (["playground", "stadium", "sports_centre", "fitness_station", "fitness_centre", "water_park"], "#DFFCE2"), // swiftlint:disable:this american_spelling_in_copy line_length
        (["golf_course", "miniature_golf", "camp_site", "caravan_site", "picnic_site"], "#DEF6C0"),
        (["pedestrian", "platform"], "#DDDDE8"),
        (["parking"], "#EEEEEE"),
        (["garages"], "#DFDDCE"),
        (["aerodrome"], "#E9E7E2"),
        (["apron"], "#DADAE0"),
        (["rest_area"], "#EFC8C8"),
        (["military"], "#F3E3DD"),
        (["religious"], "#D0D0D0"),
        (["beach"], "#FFF1BA"),
        (["sand"], "#F5E9C6"),
        (["bare_rock", "scree", "shingle"], "#EEE5DC"),
        (["mud"], "#E6DCD1"),
        (["glacier", "ice_rink"], "#DDECEC"),
        (["wetland"], "#DDE8D3"),
        (["quarry"], "#C5C3C3"),
        (["landfill"], "#B6B592"),
        (["construction", "brownfield"], "#C7C7B4"),
    ])

    static let waterLineWidths: [String: ZoomCurve] = {
        let river = ZoomCurve([(9, 0.5), (10, 0.75), (12, 1), (14, 3), (16, 6), (20, 24)])
        let stream = ZoomCurve([(12, 0.5), (14, 1), (16, 2), (20, 4)])
        return ["river": river, "canal": river, "stream": stream, "drain": stream, "ditch": stream]
    }()

    static let cliffWidth = ZoomCurve([(13, 0.5), (16, 1), (20, 2)])

    /// A pier, as Carto's `water-features.mss` draws one from zoom 12: an
    /// area filled and a line stroked square-ended in the land's color, over
    /// the water it stands in. The archive files the area under `landuse`
    /// and the line under `roads` as a path, from zoom 13.
    static let pierZ = 12
    static let pierKind = "pier"
    static let pier = Line(color: land, width: ZoomCurve([(12, 0.5), (13, 1), (14, 1), (15, 2), (16, 2), (z17, 4)]))

    /// Whether a feature of the `roads` layer is a pier, which is drawn with
    /// the water rather than as a road.
    static func isPier(kind: String?, detail: String?) -> Bool {
        kind == "path" && detail == pierKind
    }

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
        /// white dashes, a lift's cabins.
        var center: Center?
    }

    /// A narrower or a broken line drawn down the middle of another.
    struct Center: Sendable {
        let color: CGColor
        let width: ZoomCurve
        /// As ``Line/dash``: multiples of the center's own width.
        var dash: [CGFloat] = []
        /// How each dash ends: round for a lift's cabins, which Carto draws
        /// as dots.
        var cap: CGLineCap = .butt
    }

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

// MARK: - The vector extras' own layers

nonisolated extension VectorTileStyle {
    /// The border of a protected area, as Carto draws one (`admin.mss`): a
    /// thin line along it and, from zoom 10, a wide pale band just inside
    /// it, both in one green, or in brown for aboriginal lands.
    struct ProtectedBorder: Sendable {
        let color: CGColor
        /// The line along the border.
        let line: ZoomCurve
        /// The band inside it: none before zoom 10.
        let band: ZoomCurve
        /// How strongly each is drawn: Carto's is fainter once the band joins
        /// the line.
        let alpha: ZoomCurve
    }

    /// Carto draws a protected area's border from this zoom.
    static let protectedAreaZ = 8

    /// The border of a feature in the extras' `protected_areas` layer.
    static func protectedBorder(kind: String?) -> ProtectedBorder {
        ProtectedBorder(
            color: color(kind == "aboriginal_lands" ? "#82643A" : "#008000"),
            line: ZoomCurve([
                (8, protectedLineZ8), (9, protectedLineZ9), (10, protectedLineZ10), (11, protectedLineZ10), (12, 2),
            ]),
            band: ZoomCurve([(10, protectedBandZ10), (11, protectedBandZ10), (12, 4), (13, 4), (14, 6)]),
            alpha: ZoomCurve([(8, 0.25), (9, 0.25), (10, protectedAlphaZ10)])
        )
    }

    /// The style of a feature in the extras' `power` layer: a power line
    /// from zoom 14, and a minor one from 16 (`power.mss`).
    static func powerLine(kind: String?) -> Line {
        kind == "minor_line" ? minorPowerLine : majorPowerLine
    }

    /// The style of a feature in the extras' `dams` layer, as Carto's
    /// `water-features.mss` draws a dam, a weir or a lock gate mapped as a
    /// line, from zoom 13.
    static func waterBarrier(kind: String?) -> Line {
        switch kind {
        case "weir": weir
        case "lock_gate": lockGate
        default: damLine
        }
    }

    /// The style of a feature in the extras' `ridges` layer, from zoom 14:
    /// a ridge broken, an arête unbroken. Carto draws both with a pattern of
    /// its own; the map draws a line in the cliffs' gray.
    static func ridge(kind: String?) -> Line {
        kind == "arete" ? arete : ridgeLine
    }

    static let ridgeZ = 14
}

// MARK: - The figures

nonisolated private extension VectorTileStyle {
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

    static let protectedLineZ8: CGFloat = 1.2
    static let protectedLineZ9: CGFloat = 1.5
    static let protectedLineZ10: CGFloat = 1.8
    static let protectedBandZ10: CGFloat = 3.6
    static let protectedAlphaZ10: CGFloat = 0.15

    static let powerGray = color("#888888")
    static let powerWidthZ15: CGFloat = 0.6
    static let powerWidthZ16: CGFloat = 0.7
    static let powerWidthZ19: CGFloat = 1.2
    static let minorPowerWidthZ16: CGFloat = 0.3
    static let minorPowerWidthZ17: CGFloat = 0.4
    static let majorPowerLine = Line(
        color: powerGray,
        width: ZoomCurve([
            (14, 0.5), (15, powerWidthZ15), (16, powerWidthZ16), (z17, powerWidthZ16), (z18, 1), (z19, powerWidthZ19),
        ])
    )
    static let minorPowerLine = Line(
        color: powerGray,
        width: ZoomCurve([(16, minorPowerWidthZ16), (z17, minorPowerWidthZ17), (z18, 0.5)])
    )

    static let damInk = color("#444444")
    static let damWidthZ13: CGFloat = 1.6
    static let damWidthZ15: CGFloat = 2.6
    /// A dark line, with the dam's gray down it from zoom 15.
    static let damLine = Line(
        color: damInk,
        width: ZoomCurve([(13, damWidthZ13), (14, 2), (15, damWidthZ15), (16, 4)]),
        center: Center(color: dam, width: ZoomCurve([(15, 1), (16, 2)]))
    )
    static let weirGray = color("#AAAAAA")
    static let weir = Line(color: weirGray, width: ZoomCurve([(13, 2)]), dash: [1, 1])
    static let lockGate = Line(color: weirGray, width: ZoomCurve([(13, 2), (z17, 3)]))

    static let ridgeWidth = ZoomCurve([(14, 0.75), (16, 1), (20, 2)])
    static let ridgeLine = Line(color: cliff, width: ridgeWidth, dash: [2, 3])
    static let arete = Line(color: cliff, width: ridgeWidth)
}

/// A size given at a few zooms: none below the first, each zoom between two
/// stops in proportion on a doubling scale, and the last stop's past it.
nonisolated struct ZoomCurve: Sendable {
    private let stops: [(z: Int, value: CGFloat)]

    init(_ stops: [(z: Int, value: CGFloat)]) {
        self.stops = stops
    }

    /// The first zoom the curve has a size at.
    var firstZ: Int? { stops.first?.z }

    /// The same sizes from `z` on, and none below it.
    func starting(at z: Int) -> Self {
        guard let first = stops.first, z > first.z else { return self }
        return Self([(z, value(at: z))] + stops.filter { $0.z > z })
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
