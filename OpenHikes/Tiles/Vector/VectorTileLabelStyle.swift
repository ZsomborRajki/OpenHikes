//
//  VectorTileLabelStyle.swift
//  OpenHikes
//
//  What each kind of name looks like on the map, and which name wins when
//  two would overlap: the order of ``VectorTileLabelStyle/Category`` is the
//  order of importance. Sizes are in the pixels of a 256-pixel tile, as the
//  rest of ``VectorTileStyle`` is.
//

import CoreGraphics
import CoreText

nonisolated enum VectorTileLabelStyle {
    /// What a name names. Ordered by ``importance``.
    enum Category: Comparable, Sendable {
        case city
        case country
        /// An isolated dwelling or a farm.
        case dwelling
        case glacier
        case hamlet
        /// A named spot nobody lives at: a clearing, a gully, a rock face.
        case locality
        case neighborhood
        case region
        case suburb
        case town
        case village
        case water

        /// Most important first: the name that stays where two would overlap.
        private static let importance: [Self] = [
            .country, .region, .city, .town, .village, .water, .glacier, .suburb, .hamlet, .neighborhood, .dwelling,
            .locality,
        ]

        /// When a name claims its room.
        enum Turn: Sendable {
            /// After every point's name.
            case afterPoints
            /// After the names of the summits and passes, before any other
            /// point's.
            case afterSummits
            /// Before everything else on the tile.
            case first
        }

        /// A place's name comes first. Carto writes a lake's, a bay's or a
        /// glacier's with the points' own, where it orders the summits by
        /// height ahead of every area, and a locality's after them all: so
        /// a summit keeps its name where a lake's would cover it, and a hut
        /// where a gully's would.
        var turn: Turn {
            switch self {
            case .water, .glacier: .afterSummits
            case .locality: .afterPoints
            default: .first
            }
        }

        static func < (lhs: Self, rhs: Self) -> Bool {
            (importance.firstIndex(of: lhs) ?? importance.count) < (importance.firstIndex(of: rhs) ?? importance.count)
        }

        /// The category of a feature in the `places` layer, or `nil` for one
        /// not named on the map.
        static func place(kind: String?, detail: String?) -> Self? {
            switch (kind, detail) {
            case ("country", _): .country
            case ("region", _): .region
            case (_, "city"): .city
            case (_, "town"): .town
            case (_, "village"): .village
            case (_, "suburb"), (_, "quarter"): .suburb
            // swiftlint:disable:next american_spelling_in_copy
            case ("neighbourhood", _), (_, "neighbourhood"): .neighborhood
            case ("locality", "isolated_dwelling"), ("locality", "farm"): .dwelling
            case ("locality", "locality"): .locality
            case ("locality", _): .hamlet
            default: nil
            }
        }

        /// The category of a point in the `pois` layer named here rather than
        /// with an icon (``VectorTilePoints``), or `nil`: a pond's, a bay's
        /// or a glacier's name, which Carto writes over the water or the ice.
        static func poi(kind: String?) -> Self? {
            switch kind {
            case "water", "bay", "strait": .water
            case "glacier": .glacier
            default: nil
            }
        }

        /// The category of a point in the `water` layer, where the archive
        /// puts the name of a lake, a reservoir, a bay or a strait, or `nil`
        /// for one not named there: a river's or a canal's point, whose name
        /// runs along its line instead, a fountain's, or a sea's, which
        /// Carto does not name.
        static func water(kind: String?, detail: String?) -> Self? {
            switch kind {
            // A reservoir mapped as `landuse`, a basin and a dock are kinds
            // of their own in the archive, and Carto names all three.
            case "bay", "strait", "lake", "basin", "dock": .water
            case "water":
                switch detail {
                case "river", "canal", "stream", "ditch", "drain": nil
                default: .water
                }
            default: nil
            }
        }

    }

    enum Face {
        case bold
        case italic
        case regular
    }

    struct Look {
        let size: ZoomCurve
        let color: CGColor
        let face: Face
    }

    /// From zoom 12 the small places take OpenStreetMap
    /// Carto's sizes (`placenames.mss`, `amenity-points.mss`), each held
    /// between the zooms Carto changes it at.
    static func look(of category: Category) -> Look {
        switch category {
        case .country: Look(size: ZoomCurve([(3, 8), (6, 10), (8, 12)]), color: countryPurple, face: .bold)
        case .region: Look(size: ZoomCurve([(5, 8), (8, 9)]), color: countryPurple, face: .italic)
        case .city: Look(size: ZoomCurve([(4, 8), (8, 10), (12, 13), (15, 16)]), color: placeInk, face: .bold)
        case .town: Look(size: ZoomCurve([(7, 8), (10, 10), (13, 12), (15, 14)]), color: placeInk, face: .regular)
        case .village:
            Look(
                size: ZoomCurve([(10, 8), (12, 10), (13, 11), (14, 13), (15, 14), (16, 15)]),
                color: placeInk,
                face: .regular
            )
        case .hamlet:
            Look(size: ZoomCurve([(14, 10), (15, 11), (16, 12)]), color: placeInk, face: .regular)
        case .dwelling:
            Look(size: ZoomCurve([(15, 10), (16, 12)]), color: placeInk, face: .regular)
        case .locality:
            Look(size: ZoomCurve([(16, 10)]), color: placeInk, face: .regular)
        case .suburb:
            Look(
                size: ZoomCurve([(12, 11), (13, 12), (14, 14), (15, 14), (16, 15)]),
                color: neighborhoodInk,
                face: .regular
            )
        case .neighborhood: Look(size: ZoomCurve([(15, 10), (16, 12)]), color: neighborhoodInk, face: .regular)
        case .water, .glacier: Look(size: ZoomCurve([(8, 10)]), color: waterInk, face: .italic)
        }
    }

    /// The size of a lake's, a bay's or a glacier's name `zoomsPastFirst`
    /// zooms after the archive first offers it. Carto sizes one by the area
    /// it covers on the screen, 10, 12 and 15 as that quadruples, which it
    /// does with each zoom; the archive gives no area, only the zoom it
    /// thought the name first fit at, by the area. A pond first named at
    /// street level stays small however far the map is zoomed.
    static func waterSize(zoomsPastFirst: Int, firstZoom: Int) -> CGFloat {
        let sizes: [CGFloat] = firstZoom > largeWaterFirstZoom ? [10, 12] : [10, 12, 15]
        return sizes[min(max(zoomsPastFirst, 0), sizes.count - 1)]
    }

    /// Water first named no deeper than this is a lake rather than a pond.
    private static let largeWaterFirstZoom = 13

    /// The width a place's name breaks onto a new line at, between words, in
    /// multiples of its size: Carto's five ems.
    static let placeWrapEms: CGFloat = 5
    /// Taken off each line's height where a name has more than one, as a
    /// share of its size.
    static let placeLineSqueeze: CGFloat = 0.05

    /// The white edge drawn around every letter, so a name stays readable
    /// over a road or a forest.
    static let halo = VectorTileStyle.color("#FFFFFF", alpha: haloAlpha)
    static let haloWidth: CGFloat = 1.5
    /// The room kept between two names, and between a name and a tile's edge.
    static let spacing: CGFloat = 2

    static func font(size: CGFloat, face: Face, language: String) -> CTFont {
        let base: CTFont = switch face {
        case .bold: CTFontCreateUIFontForLanguage(.emphasizedSystem, size, language as CFString)
            ?? CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
        case .regular, .italic: CTFontCreateUIFontForLanguage(.system, size, language as CFString)
            ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        }
        guard face == .italic else { return base }
        return CTFontCreateCopyWithSymbolicTraits(base, size, nil, .traitItalic, .traitItalic) ?? base
    }

    private static let haloAlpha: CGFloat = 0.9
    private static let countryPurple = VectorTileStyle.color("#9D6C9D")
    private static let placeInk = VectorTileStyle.color("#222222")
    private static let neighborhoodInk = VectorTileStyle.color("#666666")
    private static let waterInk = VectorTileStyle.color("#4D80B3")
    private static let roadInk = VectorTileStyle.color("#000000")
    private static let liftInk = VectorTileStyle.color("#666666")
    private static let ridgeInk = VectorTileStyle.color("#999999")
}

// MARK: - Names along lines

nonisolated extension VectorTileLabelStyle {
    /// What a line's name names. Ordered by ``importance``.
    enum LineCategory: Comparable, Sendable {
        case aerialway
        /// Aboriginal lands, named along their edge as a protected area is.
        case aboriginalLands
        case canal
        /// A ditch or a drain.
        case ditch
        case majorRoad
        case minorRoad
        /// The number of a residential or an unclassified road.
        case minorRoadNumber
        case path
        /// A national park, a nature reserve or another protected area,
        /// named along the inside of its edge.
        case protectedArea
        /// A ridge, an arête or a cliff.
        case ridge
        case river
        case stream
        case tertiaryRoad
        /// The number of a track: a forest road's, mostly.
        case trackNumber

        /// Most important first: the name that keeps its room where two
        /// would overlap.
        private static let importance: [Self] = [
            .majorRoad, .tertiaryRoad, .minorRoad, .minorRoadNumber, .path, .trackNumber, .aerialway, .ridge,
            .river, .canal, .stream, .ditch, .protectedArea, .aboriginalLands,
        ]

        /// Whether the line's name is placed after every point's, as Carto
        /// places a waterway's (`water-lines-text`) and, after those, a
        /// protected area's (`protected-areas-text`), where the streets' and
        /// a ridge's or a cliff's (`text-line`) come before the points.
        var isPlacedAfterPoints: Bool {
            switch self {
            case .river, .canal, .stream, .ditch, .protectedArea, .aboriginalLands: true
            case .majorRoad, .tertiaryRoad, .minorRoad, .minorRoadNumber, .path, .trackNumber, .aerialway, .ridge: false
            }
        }

        /// The category a road's number is written along it under, for the
        /// roads Carto numbers so and not with a plate
        /// (`roads-text-ref-minor`): a residential or an unclassified road,
        /// and a track.
        static func number(kind: String?, detail: String?) -> Self? {
            switch (kind, detail) {
            case ("minor_road", "residential"), ("minor_road", "unclassified"): .minorRoadNumber
            case ("path", "track"): .trackNumber
            default: nil
            }
        }

        static func < (lhs: Self, rhs: Self) -> Bool {
            (importance.firstIndex(of: lhs) ?? importance.count) < (importance.firstIndex(of: rhs) ?? importance.count)
        }

        /// The category of a line in `layerName`, or `nil` for one whose
        /// name is not drawn: a railway, a ferry. A pedestrian
        /// street is a street, though the archive files it with the paths.
        static func line(in layerName: String, kind: String?, detail: String?) -> Self? {
            switch (layerName, kind) {
            case ("roads", "major_road") where detail?.hasPrefix("tertiary") == true: .tertiaryRoad
            case ("roads", "highway"), ("roads", "major_road"): .majorRoad
            case ("roads", "minor_road"): .minorRoad
            case ("roads", "path"): detail == "pedestrian" ? .minorRoad : .path
            case ("roads", "aerialway"): .aerialway
            // The archive's kind for a highway it has no other kind for.
            case ("roads", "other"): detail == "living_street" ? .minorRoad : nil
            case ("water", "river"): .river
            case ("water", "canal"): .canal
            case ("water", "stream"): .stream
            case ("water", "ditch"), ("water", "drain"): .ditch
            case (VectorTileRasterizer.ridgesLayer, _), ("earth", "cliff"): .ridge
            default: nil
            }
        }
    }

    struct LineLook {
        let size: ZoomCurve
        let color: CGColor
        let face: Face
        /// The first zoom the line carries its name at.
        let minimumZ: Int
        /// How far the name stands beside the line rather than on it, below
        /// it as the name reads: a stream's, which would hide the stream.
        var offset: CGFloat = 0
        /// The same where it changes with the zoom, as a path's does.
        var offsets: ZoomCurve?
        /// Whether the offset is to the inside of the area the line goes
        /// round, whichever way the name reads, rather than below the name:
        /// a protected area's, which Carto writes inside its edge. The
        /// archive winds every ring with the area on its right.
        var isInsideArea = false
        /// Where the name is tried on a line each tile sees only a stretch
        /// of, an area's edge: where the line crosses a grid laid over the
        /// whole world, this far apart, which every tile works out alike
        /// (``VectorTileShields/crossings(of:origin:every:)``). `nil` for
        /// marks measured from the line's middle.
        var gridSpacing: CGFloat?

        func offset(at z: Int) -> CGFloat {
            offsets?.value(at: z) ?? offset
        }
        /// The least distance between two of the same name along a line; its
        /// marks stand one and a half of this apart.
        var repeatDistance: CGFloat = lineNameRepeat
        /// The sharpest turn from one letter to the next that the name
        /// follows, in radians. A tighter bend scatters the letters.
        var bend: CGFloat = lineNameBend
    }

    /// Roads, paths and water take OpenStreetMap Carto's sizes and ink
    /// (`roads.mss`, `water.mss`), each held between the zooms Carto changes
    /// it at.
    static func look(of category: LineCategory) -> LineLook {
        switch category {
        case .majorRoad:
            LineLook(size: majorRoadSize, color: roadInk, face: .regular, minimumZ: 13)
        case .tertiaryRoad:
            LineLook(size: majorRoadSize, color: roadInk, face: .regular, minimumZ: 14)
        case .ridge:
            LineLook(
                size: ZoomCurve([(15, 10)]),
                color: ridgeInk,
                face: .regular,
                minimumZ: 15,
                offset: smallWaterOffset,
                repeatDistance: waterNameRepeat
            )
        case .minorRoad:
            LineLook(size: minorRoadSize, color: roadInk, face: .regular, minimumZ: 15)
        case .path:
            LineLook(size: pathSize, color: placeInk, face: .regular, minimumZ: 15, offsets: pathNameOffsets)
        case .minorRoadNumber, .trackNumber:
            LineLook(
                size: pathSize,
                color: roadInk,
                face: .italic,
                minimumZ: 15,
                offset: category == .trackNumber ? trackNumberOffset : 0,
                repeatDistance: roadNumberRepeat
            )
        case .aerialway:
            LineLook(
                size: ZoomCurve([(z17, 10), (z18, 10), (z19, 11)]),
                color: liftInk,
                face: .regular,
                minimumZ: z17,
                offsets: ZoomCurve([(z17, 4), (z18, 4), (z19, 5)]),
                repeatDistance: liftNameRepeat
            )
        case .river, .canal:
            LineLook(
                size: ZoomCurve([(13, 10), (14, 12)]),
                color: waterInk,
                face: category == .river ? .italic : .regular,
                minimumZ: 13,
                repeatDistance: waterNameRepeat,
                bend: waterNameBend
            )
        case .stream, .ditch:
            LineLook(
                size: ZoomCurve([(15, 10)]),
                color: waterInk,
                face: category == .stream ? .italic : .regular,
                minimumZ: 15,
                offset: smallWaterOffset,
                repeatDistance: waterNameRepeat,
                bend: waterNameBend
            )
        case .protectedArea:
            areaEdgeLook(color: VectorTileStyle.protectedArea)
        case .aboriginalLands:
            areaEdgeLook(color: VectorTileStyle.aboriginalLands)
        }
    }

    /// A protected area's name along the inside of its edge, in its
    /// border's `color`: 10 pixels inside, Carto's `text-dy` for one, and
    /// about every 750 pixels along it, its `text-spacing` (`admin.mss`).
    /// Carto measures that along the whole edge, which no tile here sees,
    /// so the name stands where the edge crosses a grid that far apart.
    private static func areaEdgeLook(color: CGColor) -> LineLook {
        LineLook(
            size: ZoomCurve([(VectorTileLineLabels.areaEdgeZ, 10)]),
            color: color,
            face: .regular,
            minimumZ: VectorTileLineLabels.areaEdgeZ,
            offset: areaEdgeOffset,
            isInsideArea: true,
            gridSpacing: areaEdgeSpacing,
            repeatDistance: areaEdgeRepeat
        )
    }

    private static let areaEdgeOffset: CGFloat = 10
    static let areaEdgeSpacing: CGFloat = 750
    /// Carto's `text-repeat-distance` for a protected area's name.
    private static let areaEdgeRepeat: CGFloat = 250

    /// A lift's name every 900 pixels and 4 beside its line, 5 from zoom
    /// 19, from zoom 17 (`aerialways.mss`): until then its stations' names
    /// say which it is.
    static let liftNameRepeat: CGFloat = 600
    /// A path's name beside its line, further the closer the map
    /// (`roads.mss`'s `text-dy` for `paths-text-name`).
    private static let pathNameOffsets = ZoomCurve([(15, 5), (16, 7), (z17, 9)])
    /// A road's number along it about every 760 pixels, Carto's
    /// `text-spacing` for one, and a track's 5 beside it
    /// (`roads-text-ref-minor`).
    static let roadNumberRepeat: CGFloat = 500
    private static let trackNumberOffset: CGFloat = 5
    /// A waterway's name every 500 pixels, Carto's `text-spacing` for one.
    static let waterNameRepeat: CGFloat = 1000 / 3
    /// Carto's `text-dy` for a stream's, a ditch's or a drain's name.
    private static let smallWaterOffset: CGFloat = 8

    private static let (z17, z18, z19) = (VectorTileStyle.z17, VectorTileStyle.z18, VectorTileStyle.z19)
    private static let majorRoadSize = ZoomCurve([
        (13, 8), (14, 9), (15, 10), (16, 10), (z17, 11), (z18, 11), (z19, 12),
    ])
    private static let minorRoadSize = ZoomCurve([(15, 8), (16, 9), (z17, 11), (z18, 11), (z19, 12)])
    private static let pathSize = ZoomCurve([(15, 8), (16, 9), (z17, 11)])

    /// The least distance between two of the same name along a long line,
    /// on one tile or either side of the edge between two. A line's marks
    /// stand one and a half of this apart: every 300 pixels, Carto's
    /// `text-spacing` for a street.
    static let lineNameRepeat: CGFloat = 200
    /// The sharpest turn from one letter to the next that a name follows,
    /// in radians: Mapnik's own 22.5 degrees, which Carto leaves as it is
    /// for a street's name.
    static let lineNameBend: CGFloat = .pi / 8
    /// Carto's 15 degrees for a waterway's name (`water.mss`).
    static let waterNameBend: CGFloat = .pi / 12
}
