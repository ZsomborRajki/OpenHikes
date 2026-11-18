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
        case hut
        case neighborhood
        case peak
        case region
        case saddle
        case town
        case village
        case water

        /// Most important first: the name that stays where two would overlap.
        private static let importance: [Self] = [
            .country, .region, .city, .town, .village, .peak, .hut, .water, .glacier, .saddle, .hamlet, .neighborhood,
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
            // swiftlint:disable:next american_spelling_in_copy
            case ("neighbourhood", _), (_, "neighbourhood"), (_, "suburb"), (_, "quarter"): .neighborhood
            case ("locality", _): .hamlet
            default: nil
            }
        }

        /// The category of a point in the `pois` layer, or `nil` for one not
        /// named on the map. The map names what a hiker finds their way by,
        /// and leaves the benches and cafés to the places screens.
        static func poi(kind: String?) -> Self? {
            switch kind {
            case "peak", "volcano": .peak
            case "alpine_hut", "wilderness_hut": .hut
            case "water": .water
            case "glacier": .glacier
            case "saddle": .saddle
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

        /// Whether the name stands under a symbol drawn at its point, rather
        /// than over the point itself.
        var hasMarker: Bool { self == .peak || self == .hut }
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

    static func look(of category: Category) -> Look {
        switch category {
        case .country: Look(size: ZoomCurve([(3, 8), (6, 10), (8, 12)]), color: countryPurple, face: .bold)
        case .region: Look(size: ZoomCurve([(5, 8), (8, 9)]), color: countryPurple, face: .italic)
        case .city: Look(size: ZoomCurve([(4, 8), (8, 10), (12, 13), (15, 16)]), color: placeInk, face: .bold)
        case .town: Look(size: ZoomCurve([(7, 8), (10, 10), (13, 12), (15, 14)]), color: placeInk, face: .regular)
        case .village: Look(size: ZoomCurve([(10, 8), (13, 10), (15, 12)]), color: placeInk, face: .regular)
        case .hamlet: Look(size: ZoomCurve([(12, 7), (14, 9), (16, 10)]), color: placeInk, face: .regular)
        case .neighborhood: Look(size: ZoomCurve([(12, 7), (15, 9)]), color: neighborhoodInk, face: .regular)
        case .peak, .saddle: Look(size: ZoomCurve([(12, 7), (15, 8), (16, 9)]), color: terrainInk, face: .regular)
        case .hut: Look(size: ZoomCurve([(14, 7), (15, 8), (16, 9)]), color: terrainInk, face: .bold)
        case .water, .glacier: Look(size: ZoomCurve([(8, 7), (12, 8), (15, 10)]), color: waterInk, face: .italic)
        }
    }

    /// The white edge drawn around every letter, so a name stays readable
    /// over a road or a forest.
    static let halo = VectorTileStyle.color("#FFFFFF", alpha: haloAlpha)
    static let haloWidth: CGFloat = 1.5
    /// The room kept between two names, and between a name and a tile's edge.
    static let spacing: CGFloat = 2
    /// The gap between a symbol and the name under it.
    static let markerGap: CGFloat = 1
    /// A height or a second line, as a share of the name's size.
    static let detailScale: CGFloat = 0.85
    /// A hut's symbol, drawn from zoom 14, the zoom its name starts at.
    static let hutZ = 14
    static let hutSize = ZoomCurve([(14, 4), (16, 5), (20, 6)])

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
    private static let terrainInk = VectorTileStyle.color("#6B4A2E")
    private static let waterInk = VectorTileStyle.color("#4D80B3")
    private static let roadInk = VectorTileStyle.color("#333333")
    private static let liftInk = VectorTileStyle.color("#555555")
}

// MARK: - Names along lines

nonisolated extension VectorTileLabelStyle {
    /// What a line's name names. Ordered by ``importance``.
    enum LineCategory: Comparable, Sendable {
        case aerialway
        case majorRoad
        case minorRoad
        case path
        case river
        case stream

        /// Most important first: the name that keeps its room where two
        /// would overlap. Every point name comes before any of these.
        private static let importance: [Self] = [.majorRoad, .river, .minorRoad, .path, .aerialway, .stream]

        static func < (lhs: Self, rhs: Self) -> Bool {
            (importance.firstIndex(of: lhs) ?? importance.count) < (importance.firstIndex(of: rhs) ?? importance.count)
        }

        /// The category of a line in `layerName`, or `nil` for one whose
        /// name is not drawn: a railway, a ferry, a ditch. A pedestrian
        /// street is a street, though the archive files it with the paths.
        static func line(in layerName: String, kind: String?, detail: String?) -> Self? {
            switch (layerName, kind) {
            case ("roads", "highway"), ("roads", "major_road"): .majorRoad
            case ("roads", "minor_road"): .minorRoad
            case ("roads", "path"): detail == "pedestrian" ? .minorRoad : .path
            case ("roads", "aerialway"): .aerialway
            // The archive's kind for a highway it has no other kind for.
            case ("roads", "other"): detail == "living_street" ? .minorRoad : nil
            case ("water", "river"), ("water", "canal"): .river
            case ("water", "stream"): .stream
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
    }

    static func look(of category: LineCategory) -> LineLook {
        switch category {
        case .majorRoad:
            LineLook(size: ZoomCurve([(13, 8), (15, 9), (16, 10)]), color: roadInk, face: .regular, minimumZ: 13)
        case .minorRoad:
            LineLook(size: ZoomCurve([(15, 7), (16, 8), (20, 9)]), color: roadInk, face: .regular, minimumZ: 15)
        case .path:
            LineLook(size: ZoomCurve([(15, 7), (16, 8)]), color: terrainInk, face: .regular, minimumZ: 15)
        case .aerialway:
            LineLook(size: ZoomCurve([(14, 7), (16, 8)]), color: liftInk, face: .regular, minimumZ: 14)
        case .river:
            LineLook(size: ZoomCurve([(12, 8), (15, 9), (16, 10)]), color: waterInk, face: .italic, minimumZ: 12)
        case .stream:
            LineLook(size: ZoomCurve([(15, 7), (16, 8)]), color: waterInk, face: .italic, minimumZ: 15)
        }
    }

    /// The least distance between two of the same name along a long line,
    /// on one tile or either side of the edge between two.
    static let lineNameRepeat: CGFloat = 100
    /// The sharpest turn from one letter to the next that a name follows,
    /// in radians: about thirty degrees. A tighter bend scatters the letters.
    static let lineNameBend: CGFloat = 0.5
}
