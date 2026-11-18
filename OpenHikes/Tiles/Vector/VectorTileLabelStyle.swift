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
        case glacier
        case hamlet
        case neighborhood
        case region
        case suburb
        case town
        case village
        case water

        /// Most important first: the name that stays where two would overlap.
        private static let importance: [Self] = [
            .country, .region, .city, .town, .village, .water, .glacier, .suburb, .hamlet, .neighborhood,
        ]

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
            case ("locality", _): .hamlet
            default: nil
            }
        }

        /// The category of a point in the `pois` layer named here rather than
        /// with an icon (``VectorTilePoints``), or `nil`: a pond's or a
        /// glacier's name, which Carto writes over the water or the ice.
        static func poi(kind: String?) -> Self? {
            switch kind {
            case "water": .water
            case "glacier": .glacier
            default: nil
            }
        }

        /// The category of a point in the `water` layer, where the archive
        /// puts the name of a lake or a reservoir, or `nil` for one not named
        /// there: a river's or a canal's point, whose name runs along its
        /// line instead, or a fountain's.
        static func water(kind: String?, detail: String?) -> Self? {
            guard kind == "water" else { return nil }
            return switch detail {
            case "river", "canal", "stream", "ditch", "drain": nil
            default: .water
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
            Look(size: ZoomCurve([(12, 8), (14, 10), (15, 11), (16, 12)]), color: placeInk, face: .regular)
        case .suburb:
            Look(
                size: ZoomCurve([(12, 11), (13, 12), (14, 14), (15, 14), (16, 15)]),
                color: neighborhoodInk,
                face: .regular
            )
        case .neighborhood: Look(size: ZoomCurve([(15, 10), (16, 12)]), color: neighborhoodInk, face: .regular)
        case .water, .glacier: Look(size: ZoomCurve([(8, 7), (12, 8), (15, 10)]), color: waterInk, face: .italic)
        }
    }

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
    private static let liftInk = VectorTileStyle.color("#555555")
}

// MARK: - Names along lines

nonisolated extension VectorTileLabelStyle {
    /// What a line's name names. Ordered by ``importance``.
    enum LineCategory: Comparable, Sendable {
        case aerialway
        case canal
        /// A ditch or a drain.
        case ditch
        case majorRoad
        case minorRoad
        case path
        case river
        case stream

        /// Most important first: the name that keeps its room where two
        /// would overlap.
        private static let importance: [Self] = [
            .majorRoad, .minorRoad, .path, .aerialway, .river, .canal, .stream, .ditch,
        ]

        /// Whether the line is water, whose names Carto places after every
        /// point's name, where streets' come before.

        var isWater: Bool {
            switch self {
            case .river, .canal, .stream, .ditch: true
            case .majorRoad, .minorRoad, .path, .aerialway: false
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
        /// The least distance between two of the same name along a line; its
        /// marks stand one and a half of this apart.
        var repeatDistance: CGFloat = lineNameRepeat
    }

    /// Roads, paths and water take OpenStreetMap Carto's sizes and ink
    /// (`roads.mss`, `water.mss`), each held between the zooms Carto changes
    /// it at.
    static func look(of category: LineCategory) -> LineLook {
        switch category {
        case .majorRoad:
            LineLook(size: majorRoadSize, color: roadInk, face: .regular, minimumZ: 13)
        case .minorRoad:
            LineLook(size: minorRoadSize, color: roadInk, face: .regular, minimumZ: 15)
        case .path:
            LineLook(size: pathSize, color: placeInk, face: .regular, minimumZ: 15)
        case .aerialway:
            LineLook(size: ZoomCurve([(14, 7), (16, 8)]), color: liftInk, face: .regular, minimumZ: 14)
        case .river, .canal:
            LineLook(
                size: ZoomCurve([(13, 10), (14, 12)]),
                color: waterInk,
                face: category == .river ? .italic : .regular,
                minimumZ: 13,
                repeatDistance: waterNameRepeat
            )
        case .stream, .ditch:
            LineLook(
                size: ZoomCurve([(15, 10)]),
                color: waterInk,
                face: category == .stream ? .italic : .regular,
                minimumZ: 15,
                offset: smallWaterOffset,
                repeatDistance: waterNameRepeat
            )
        }
    }

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
    /// in radians: about thirty degrees. A tighter bend scatters the letters.
    static let lineNameBend: CGFloat = 0.5
}
