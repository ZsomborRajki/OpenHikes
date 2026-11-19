//
//  VectorTilePointStyle.swift
//  OpenHikes
//
//  How each kind of point in the archive's `pois` layer is drawn: its icon
//  and color, the zoom it appears from, and the name written under it. The
//  figures are OpenStreetMap Carto's, the style tile.openstreetmap.org draws,
//  read out of its rules by `Scripts/carto-points.sh` into
//  `VectorTilePoints.json`, with the icons they name in `CartoIcons.xcassets`.
//  Carto's style and icons are CC0. Re-run the script to move to another
//  Carto release; nothing here is written by hand.
//
//  The archive names a point by its tag's value alone (`parking`, not
//  `amenity=parking`), and the table is keyed the same way. A kind can come
//  in variants: a place of worship's religion and a pitch's sport, which the
//  archive keeps in `kind_detail`, a car park's `parking`, which the vector
//  extras keep there, and, for the few kinds Carto draws differently once
//  named, whether it has a name.
//
//  The stops Carto draws in a layer of its own, `stations.mss` — railway
//  stations and halts, tram stops and subway entrances — are in the same
//  table, each marked with its place in that layer's order.
//
//  Carto draws some points differently where their `access` is one its
//  queries count as restricted (`private`, `customers`…): a private car
//  park's icon and name faded, a private toilet only from a deeper zoom, a
//  private elevator not at all. Those kinds carry a second set of bands, and
//  the table lists the values, both read out of Carto as the rest is.
//
//  An area is drawn at a point inside it, and Carto also looks at its size
//  on the screen: a forest is named from zoom 8 once it covers 3,000 square
//  pixels, and in a larger size the larger it is; a car park is marked from
//  zoom 14 once it covers 750. The kinds Carto draws by their size carry a
//  set of bands for each range of sizes its rules tell apart. The vector
//  extras give an area's size; a point the basemap gives has none, and is
//  drawn as a point is. An area past ``areaLimit`` is not drawn at a point at
//  all, as in Carto, which names a protected area that large along its edge
//  instead; the map does not draw those names.
//

import CoreGraphics
import Foundation

nonisolated struct VectorTilePointStyle: Sendable {
    /// The Carto release the table was read from.
    let source: String
    /// The `access` values Carto draws a point as restricted for.
    private let restrictedAccess: Set<String>
    /// The largest area Carto draws at a point, in the square pixels of a
    /// 256-pixel tile at the zoom drawn.
    let areaLimit: Double
    private let entries: [String: [Entry]]

    /// How a point of one kind is drawn at one zoom.
    struct Look: Sendable {
        /// Drawn after everything else, and only where room is left: benches,
        /// bins, gates and wayside crosses.
        let lowPriority: Bool
        /// Where one of Carto's stations — a railway station or halt, a tram
        /// stop or a subway entrance — stands in the order of their own
        /// layer, which places them right after the names of places: a
        /// station before a halt or a tram stop, and those before a subway
        /// entrance. `nil` for every other point.
        let stationOrder: Int?
        /// Whether the name carries the point's height under it, as a
        /// summit's, a pass's or a hut's does.
        let showsElevation: Bool
        let icons: [Icon]
        let text: Text?

        var isStation: Bool { stationOrder != nil }
    }

    struct Icon: Sendable {
        /// The icon in `CartoIcons.xcassets`, or none for a plain dot.
        let asset: String?
        /// None for an icon drawn in its own colors.
        let fill: CGColor?
        /// In the pixels of a 256-pixel tile, as every size in the style is.
        let size: CGSize
        let opacity: CGFloat
        /// A dot's outline: none where it has none.
        let outline: (color: CGColor, width: CGFloat)?
        /// Drawn even where something else stands.
        let allowsOverlap: Bool
        /// Leaves its room to whatever is placed after it.
        let ignoresPlacement: Bool
    }

    struct Text: Sendable {
        let size: CGFloat
        let color: CGColor
        let halo: CGColor
        let haloRadius: CGFloat
        /// From the point down to the top of the name; above it where negative.
        let offset: CGFloat
        /// The width a name breaks onto a new line at, between words.
        let wrapWidth: CGFloat
        /// Added to each line's height: Carto draws a name's lines close.
        let lineSpacing: CGFloat
        let face: VectorTileLabelStyle.Face
        let opacity: CGFloat
    }

    /// How a point of `kind` is drawn at zoom `z`, or `nil` where Carto draws
    /// nothing of it there.
    /// - Parameters:
    ///   - detail: the archive's `kind_detail`: a religion, a sport, a car
    ///     park's `parking` or a protected area's class.
    ///   - named: whether the point has a name.
    ///   - access: the point's `access` tag, where the archive carries it.
    ///   - pixels: the size of the area the point stands for, at zoom `z`,
    ///     where the archive gives one.
    func look(
        kind: String,
        detail: String?,
        named: Bool,
        z: Int,
        access: String? = nil,
        pixels: Double? = nil
    ) -> Look? {
        guard let variants = entries[kind] else { return nil }
        let fitting = variants.filter { $0.naming.admits(named: named) }
        let entry = fitting.first { $0.detail != nil && $0.detail == detail } ?? fitting.first { $0.detail == nil }
        guard let entry else { return nil }
        let restricted = access.map(restrictedAccess.contains) == true
        var bands = restricted ? entry.restricted : entry.bands
        if let pixels {
            guard pixels < areaLimit else { return nil }
            let areas = restricted ? entry.restrictedAreas : entry.areas
            if let range = areas.last(where: { $0.above < pixels }) { bands = range.bands }
        }
        guard let band = bands.first(where: { $0.zooms.contains(z) }) else { return nil }
        return Look(
            lowPriority: entry.lowPriority,
            stationOrder: entry.stationOrder,
            showsElevation: entry.showsElevation,
            icons: band.icons,
            text: band.text
        )
    }

    private init(source: String, restrictedAccess: Set<String>, areaLimit: Double, entries: [String: [Entry]]) {
        self.source = source
        self.restrictedAccess = restrictedAccess
        self.areaLimit = areaLimit
        self.entries = entries
    }

    /// Every icon the table names, which `CartoIcons.xcassets` must hold.
    var assets: Set<String> {
        let bands = entries.values.joined().flatMap { entry in
            entry.bands + entry.restricted + (entry.areas + entry.restrictedAreas).flatMap(\.bands)
        }
        return Set(bands.flatMap(\.icons).compactMap(\.asset))
    }

    /// How many kinds the table draws.
    var kindCount: Int { entries.count }

    private struct Entry: Sendable {
        let detail: String?
        let naming: Naming
        let lowPriority: Bool
        let stationOrder: Int?
        let showsElevation: Bool
        let bands: [Band]
        /// How Carto draws the point where its access is restricted: the
        /// same as `bands` for most kinds, and nothing where it is empty.
        let restricted: [Band]
        /// How an area of the kind is drawn, by its size, smallest range
        /// first: empty for a kind Carto draws the same at any size, and an
        /// area smaller than the first range is drawn as a point is.
        let areas: [AreaBands]
        /// The same where its access is restricted.
        let restrictedAreas: [AreaBands]
    }

    /// The bands for an area larger than `above` pixels, until the next
    /// range's.
    private struct AreaBands: Sendable {
        let above: Double
        let bands: [Band]
    }

    private struct Band: Sendable {
        let zooms: ClosedRange<Int>
        let icons: [Icon]
        let text: Text?
    }

    /// Which points a variant is for: the few kinds Carto draws differently
    /// once named have one of each.
    private enum Naming: Sendable {
        case either
        case named
        case unnamed

        func admits(named: Bool) -> Bool {
            switch self {
            case .either: true
            case .named: named
            case .unnamed: !named
            }
        }
    }
}

// MARK: - Reading the table

nonisolated extension VectorTilePointStyle {
    /// The table the app ships, or an empty one where it cannot be read:
    /// the map is then drawn without its points.
    static let bundled: Self = {
        guard let url = Bundle.main.url(forResource: "VectorTilePoints", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let style = try? Self(json: data)
        else { return Self(source: "", restrictedAccess: [], areaLimit: 0, entries: [:]) }
        return style
    }()

    /// The table `Scripts/carto-points.sh` writes.
    init(json: Data) throws {
        let file = try JSONDecoder().decode(File.self, from: json)
        source = file.source
        restrictedAccess = Set(file.restrictedAccess)
        areaLimit = file.areaLimit
        entries = Dictionary(grouping: file.entries, by: \.kind).mapValues { entries in
            entries.map { entry in
                Entry(
                    detail: entry.detail,
                    naming: entry.naming,
                    lowPriority: entry.lowPriority,
                    stationOrder: entry.stationOrder,
                    showsElevation: entry.showsElevation,
                    bands: entry.bands.map(\.band),
                    restricted: entry.restricted.map(\.band),
                    areas: entry.areas.map(\.areaBands),
                    restrictedAreas: entry.restrictedAreas.map(\.areaBands)
                )
            }
        }
    }

    /// The file as the script writes it.
    private struct File: Decodable {
        let source: String
        let restrictedAccess: [String]
        let areaLimit: Double
        let entries: [FileEntry]
    }

    /// An entry as written, where `named`, `station`, `elevation`,
    /// `restricted`, `areas` and `restrictedAreas` are left out rather than
    /// written for the many kinds they do not concern: a kind without
    /// `restricted` is drawn the same whatever its access, and one without
    /// `areas` the same whatever its size.
    private struct FileEntry: Decodable {
        let kind: String
        let detail: String?
        let naming: Naming
        let lowPriority: Bool
        let stationOrder: Int?
        let showsElevation: Bool
        let bands: [FileBand]
        let restricted: [FileBand]
        let areas: [FileAreaBands]
        let restrictedAreas: [FileAreaBands]

        private enum CodingKeys: String, CodingKey {
            case kind = "kind"
            case detail = "detail"
            case named = "named"
            case lowPriority = "lowPriority"
            case station = "station"
            case elevation = "elevation"
            case bands = "bands"
            case restricted = "restricted"
            case areas = "areas"
            case restrictedAreas = "restrictedAreas"
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            kind = try container.decode(String.self, forKey: .kind)
            detail = try container.decodeIfPresent(String.self, forKey: .detail)
            naming = try container.decodeIfPresent(Bool.self, forKey: .named)
                .map { $0 ? Naming.named : .unnamed } ?? .either
            lowPriority = try container.decode(Bool.self, forKey: .lowPriority)
            stationOrder = try container.decodeIfPresent(Int.self, forKey: .station)
            showsElevation = try container.decodeIfPresent(Bool.self, forKey: .elevation) ?? false
            bands = try container.decode([FileBand].self, forKey: .bands)
            restricted = try container.decodeIfPresent([FileBand].self, forKey: .restricted) ?? bands
            areas = try container.decodeIfPresent([FileAreaBands].self, forKey: .areas) ?? []
            restrictedAreas = try container.decodeIfPresent([FileAreaBands].self, forKey: .restrictedAreas) ?? areas
        }
    }

    private struct FileAreaBands: Decodable {
        let above: Double
        let bands: [FileBand]

        var areaBands: AreaBands {
            AreaBands(above: above, bands: bands.map(\.band))
        }
    }

    private struct FileBand: Decodable {
        let from: Int
        let to: Int
        let icons: [FileIcon]
        let text: FileText?

        var band: Band {
            Band(zooms: from...max(from, to), icons: icons.map(\.icon), text: text?.text)
        }
    }

    /// An icon as written, where Mapnik's defaults are left out.
    private struct FileIcon: Decodable {
        let asset: String?
        let fill: String?
        let width: Double
        let height: Double
        let opacity: Double?
        let lineWidth: Double?
        let lineColor: String?
        let allowOverlap: Bool
        let ignorePlacement: Bool

        private enum CodingKeys: String, CodingKey {
            case asset = "asset"
            case fill = "fill"
            case width = "width"
            case height = "height"
            case opacity = "opacity"
            case lineWidth = "lineWidth"
            case lineColor = "lineColor"
            case allowOverlap = "allowOverlap"
            case ignorePlacement = "ignorePlacement"
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            asset = try container.decodeIfPresent(String.self, forKey: .asset)
            fill = try container.decodeIfPresent(String.self, forKey: .fill)
            width = try container.decode(Double.self, forKey: .width)
            height = try container.decode(Double.self, forKey: .height)
            opacity = try container.decodeIfPresent(Double.self, forKey: .opacity)
            lineWidth = try container.decodeIfPresent(Double.self, forKey: .lineWidth)
            lineColor = try container.decodeIfPresent(String.self, forKey: .lineColor)
            allowOverlap = try container.decodeIfPresent(Bool.self, forKey: .allowOverlap) ?? false
            ignorePlacement = try container.decodeIfPresent(Bool.self, forKey: .ignorePlacement) ?? false
        }

        var icon: Icon {
            let outline = lineWidth.flatMap { width in
                width > 0 ? (VectorTileStyle.color(lineColor ?? "#000000"), CGFloat(width)) : nil
            }
            return Icon(
                asset: asset,
                fill: fill.map { VectorTileStyle.color($0) },
                size: CGSize(width: width, height: height),
                opacity: CGFloat(opacity ?? 1),
                outline: outline,
                allowsOverlap: allowOverlap,
                ignoresPlacement: ignorePlacement
            )
        }
    }

    private struct FileText: Decodable {
        let field: String
        let size: Double
        let fill: String
        let halo: String
        let haloRadius: Double
        let dy: Double
        let wrapWidth: Double
        let lineSpacing: Double
        let face: String
        let opacity: Double?

        /// The name, or nothing: the archive keeps no `ref` or `operator`.
        var text: Text? {
            guard field == "name" else { return nil }
            let typeface: VectorTileLabelStyle.Face = switch face {
            case "italic": .italic
            case "bold": .bold
            default: .regular
            }
            return Text(
                size: CGFloat(size),
                color: VectorTileStyle.color(fill),
                halo: VectorTileStyle.color(halo),
                haloRadius: CGFloat(haloRadius),
                offset: CGFloat(dy),
                wrapWidth: CGFloat(wrapWidth),
                lineSpacing: CGFloat(lineSpacing),
                face: typeface,
                opacity: CGFloat(opacity ?? 1)
            )
        }
    }
}
