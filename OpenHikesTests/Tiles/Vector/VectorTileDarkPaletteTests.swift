//
//  VectorTileDarkPaletteTests.swift
//  OpenHikesTests
//
//  OpenHikes Dark's colors: the table is well formed, it names a color of
//  its own for everything the map is mostly made of, rather than leaving it
//  to the rule, and the colors it names keep the promises its header makes:
//  dark ground, light names, water and streets lighter than the land.
//

import CoreGraphics
import Foundation
@testable import OpenHikes
import RealModule
import Testing

@Suite("OpenHikes Dark's palette")
struct VectorTileDarkPaletteTests {
    private let dark = VectorTilePalette.dark

    private static let shared = VectorTileDarkPalette.ground + VectorTileDarkPalette.lines
        + VectorTileDarkPalette.points
    private static let tables: [(name: String, pairs: [VectorTileDarkPalette.Pair])] = [
        ("shared", shared),
        ("fills", VectorTileDarkPalette.fills),
        ("surfaces", VectorTileDarkPalette.surfaces),
        ("casings", VectorTileDarkPalette.casings),
        ("halos", VectorTileDarkPalette.halos),
        ("text", VectorTileDarkPalette.text),
        ("patterns", VectorTileDarkPalette.patterns),
    ]

    // MARK: The table

    @Test("every entry is two colors, and no table names one of Carto's twice")
    func wellFormed() {
        for table in Self.tables {
            var seen: Set<UInt32> = []
            for pair in table.pairs {
                let carto = VectorTilePalette.rgb(hex: pair.carto)
                #expect(carto != nil, "\(table.name): \(pair.carto)")
                #expect(VectorTilePalette.rgb(hex: pair.own) != nil, "\(table.name): \(pair.own)")
                guard let carto else { continue }
                #expect(seen.insert(carto).inserted, "\(table.name) names \(pair.carto) twice")
            }
        }
    }

    @Test("the palette is the dark map's, and not Carto's")
    func identity() {
        #expect(dark.isDark)
        #expect(!dark.isCarto)
        #expect(dark.name == "dark")
    }

    // MARK: What it names

    @Test("the ground and the water have colors of their own")
    func namesTheGround() {
        let ground = [
            VectorTileStyle.land, VectorTileStyle.water, VectorTileStyle.ocean, VectorTileStyle.building,
            VectorTileStyle.park, VectorTileStyle.dam, VectorTileStyle.bridgeArea, VectorTileStyle.mud,
            VectorTileStyle.waterTunnelFill, VectorTileStyle.breakwater.color,
        ]
        let fills = Array(VectorTileStyle.landuseFills.values) + Array(VectorTileStyle.landcoverFills.values)
        for color in ground + fills {
            #expect(dark.names(color, as: .fill), "\(String(describing: color.components))")
        }
    }

    private static let ways: [(kind: String, detail: String)] = [
        ("highway", "motorway"), ("highway", "motorway_link"), ("major_road", "trunk"), ("major_road", "primary"),
        ("major_road", "secondary"), ("major_road", "tertiary"), ("minor_road", "residential"),
        ("minor_road", "service"), ("other", "living_street"), ("path", "pedestrian"), ("rail", "rail"),
        ("rail", "tram"), ("rail", "subway"), ("rail", "light_rail"), ("rail", "disused"), ("rail", "miniature"),
        ("ferry", ""), ("aeroway", "runway"), ("aerialway", "gondola"), ("aerialway", "chair_lift"),
        ("aerialway", "goods"),
    ]

    @Test("every street's surface and casing, and every railway and lift, has a color of its own")
    func namesTheWays() throws {
        for way in Self.ways {
            let road = try #require(VectorTileStyle.road(kind: way.kind, detail: way.detail), "\(way)")
            for line in [road.line, road.far].compactMap(\.self) {
                let role: VectorTilePalette.Role = line.casing == nil ? .line : .surface
                #expect(dark.names(line.color, as: role), "\(way)")
                if let casing = line.casing { #expect(dark.names(casing, as: .casing), "\(way) casing") }
                if let center = line.center { #expect(dark.names(center.color, as: .line), "\(way) center") }
            }
        }
    }

    @Test("every path, open and closed, has a color of its own", arguments: VectorTileStyle.PathKind.allCases)
    func namesThePaths(kind: VectorTileStyle.PathKind) throws {
        for isClosed in [false, true] {
            let traits = VectorTileStyle.PathTraits(kind: kind, isClosed: isClosed)
            let look = try #require(VectorTileStyle.path(traits, z: VectorTileStyle.z17))
            #expect(dark.names(look.color, as: .line), "\(kind), closed: \(isClosed)")
        }
        #expect(dark.names(VectorTileStyle.pathBand, as: .halo))
        #expect(dark.names(VectorTileStyle.pathBridgeCasingColor, as: .line))
        #expect(dark.names(VectorTileStyle.pathTunnelCasingColor, as: .line))
    }

    private static let places: [VectorTileLabelStyle.Category] = [
        .city, .country, .dwelling, .glacier, .hamlet, .locality, .neighborhood, .region, .suburb, .town,
        .village, .water,
    ]
    private static let lineNames: [VectorTileLabelStyle.LineCategory] = [
        .aerialway, .aboriginalLands, .canal, .ditch, .majorRoad, .minorRoad, .minorRoadNumber, .path,
        .protectedArea, .ridge, .river, .stream, .tertiaryRoad, .trackNumber,
    ]

    @Test("every name's ink and its halo have colors of their own")
    func namesTheText() {
        for category in Self.places {
            #expect(dark.names(VectorTileLabelStyle.look(of: category).color, as: .text), "\(category)")
        }
        for category in Self.lineNames {
            #expect(dark.names(VectorTileLabelStyle.look(of: category).color, as: .text), "\(category)")
        }
        #expect(dark.names(VectorTileLabelStyle.halo, as: .halo))
        #expect(dark.names(VectorTileArrows.halo, as: .halo))
    }

    @Test("every road's plate and every one-way arrow has colors of its own")
    func namesPlatesAndArrows() {
        for road in VectorTileShields.Road.allCases {
            let colors = road.colors
            #expect(dark.names(colors.fill, as: .surface), "\(road)")
            #expect(dark.names(colors.edge, as: .casing), "\(road)")
            #expect(dark.names(colors.ink, as: .text), "\(road)")
        }
        for kind in VectorTileArrows.Kind.importance {
            #expect(dark.names(kind.arrow.color, as: .text), "\(kind)")
        }
    }

    /// Carto's table is read out of a release by a script, so a newer one
    /// can bring a color nobody has picked a counterpart for. The rule draws
    /// it readably all the same; the colors most points are drawn in are
    /// held to having one picked.
    @Test("the colors most points' icons and names are drawn in have colors of their own")
    func namesTheCommonestPointColors() throws {
        let url = try #require(Bundle.main.url(forResource: "VectorTilePoints", withExtension: "json"))
        let table = try String(contentsOf: url, encoding: .utf8)
        var counts: [String: Int] = [:]
        for match in table.matches(of: /"fill" : "(#[0-9A-Fa-f]{6})"/) {
            counts[String(match.output.1).uppercased(), default: 0] += 1
        }
        let commonest = counts.filter { $0.value >= Self.commonUses }.keys.sorted()
        #expect(commonest.count >= Self.fewestCommon, "the table has changed its shape: \(counts.count) colors")
        for hex in commonest {
            let color = VectorTileStyle.color(hex)
            #expect(dark.names(color, as: .icon) && dark.names(color, as: .text), "\(hex)")
        }
    }

    private static let commonUses = 40
    private static let fewestCommon = 6

    // MARK: What it promises

    /// A color's relative luminance, as WCAG works it out.
    private func luminance(_ color: CGColor) -> Double {
        guard let rgb = VectorTilePalette.components(of: color)?.rgb else { return .nan }
        let channel = { (shift: UInt32) -> Double in
            let encoded = Double((rgb >> shift) & 0xFF) / 255
            return encoded <= 0.04045 ? encoded / 12.92 : pow((encoded + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0)
    }

    /// WCAG's contrast ratio between two colors, 1 for none to 21.
    private func contrast(_ lhs: CGColor, _ rhs: CGColor) -> Double {
        let (light, dim) = (max(luminance(lhs), luminance(rhs)), min(luminance(lhs), luminance(rhs)))
        return (light + 0.05) / (dim + 0.05)
    }

    private func fill(_ kind: String) throws -> CGColor {
        dark.color(try #require(VectorTileStyle.landuseFills[kind]), as: .fill)
    }

    @Test("the ground is dark, and no ground outshines a name on it")
    func groundIsDark() {
        let land = dark.color(VectorTileStyle.land, as: .fill)
        #expect(luminance(land) < 0.02)
        let place = dark.color(VectorTileLabelStyle.look(of: .town).color, as: .text)
        let street = dark.color(VectorTileLabelStyle.look(of: .minorRoad).color, as: .text)
        let fills = Array(VectorTileStyle.landuseFills.values) + Array(VectorTileStyle.landcoverFills.values)
        for carto in fills + [VectorTileStyle.land, VectorTileStyle.water, VectorTileStyle.building] {
            let ground = dark.color(carto, as: .fill)
            #expect(contrast(place, ground) >= 7, "\(String(describing: carto.components))")
            #expect(contrast(street, ground) >= 4.5, "\(String(describing: carto.components))")
        }
    }

    @Test("a halo is darker than the land it cuts a name out of")
    func haloIsTheDarkGround() {
        let halo = dark.color(VectorTileLabelStyle.halo, as: .halo)
        #expect(luminance(halo) < luminance(dark.color(VectorTileStyle.land, as: .fill)))
        #expect(halo.alpha.isApproximatelyEqual(to: VectorTileLabelStyle.halo.alpha, absoluteTolerance: 0.001))
    }

    @Test("water is lighter than the land and the woods, so a stream is found in either")
    func waterStandsOut() throws {
        let water = dark.color(VectorTileStyle.water, as: .fill)
        #expect(contrast(water, dark.color(VectorTileStyle.land, as: .fill)) >= 1.6)
        #expect(contrast(water, try fill("forest")) >= 1.3)
        #expect(luminance(water) > luminance(try fill("forest")))
    }

    @Test("what grows keeps Carto's order: a wood is darker than a meadow")
    func woodsAreDarkerThanMeadows() throws {
        #expect(luminance(try fill("forest")) < luminance(try fill("grass")))
        #expect(luminance(try fill("farmland")) < luminance(try fill("grass")))
    }

    @Test("a street is lighter than the ground it crosses, and cased darker than it")
    func streetsStandOut() throws {
        let street = try #require(VectorTileStyle.road(kind: "minor_road", detail: "residential")).line
        let surface = dark.color(street.color, as: .surface)
        let casing = dark.color(try #require(street.casing), as: .casing)
        let residential = try fill("residential")
        #expect(contrast(surface, residential) >= 1.8)
        #expect(luminance(casing) < luminance(dark.color(VectorTileStyle.land, as: .fill)))
        // The same white is a street's surface and a railway's dashes.
        #expect(luminance(dark.color(street.color, as: .line)) < luminance(residential))
    }

    @Test("the classed roads keep Carto's hues")
    func roadsKeepTheirHues() throws {
        let motorway = try #require(VectorTileStyle.road(kind: "highway", detail: "motorway")).line.color
        let rgb = try #require(VectorTilePalette.components(of: dark.color(motorway, as: .surface))).rgb
        #expect((rgb >> 16) & 0xFF > (rgb >> 8) & 0xFF, "a motorway is still red")
        let secondary = try #require(VectorTileStyle.road(kind: "major_road", detail: "secondary")).line.color
        let yellow = try #require(VectorTilePalette.components(of: dark.color(secondary, as: .surface))).rgb
        #expect((yellow >> 8) & 0xFF > yellow & 0xFF, "a secondary road is still yellow")
    }

    // MARK: On the picture

    private let tile = VectorTileAddress(z: 14, x: 8800, y: 5700)
    private let whole = 0...VectorTileFixture.grid

    private var layers: [VectorTileFixture.Layer] {
        [
            .init(name: "earth", features: [
                .init(
                    type: .polygon,
                    properties: ["kind": .string("earth")],
                    geometry: VectorTileFixture.rectangle(x: whole, y: whole)
                ),
            ]),
            .init(name: "roads", features: [
                .init(
                    type: .line,
                    properties: ["kind": .string("minor_road"), "kind_detail": .string("residential")],
                    geometry: VectorTileFixture.line([(0, 2048), (VectorTileFixture.grid, 2048)])
                ),
            ]),
        ]
    }

    @Test("a tile drawn in the dark palette is the dark map's picture, and in Carto's the light map's")
    func drawsDark() throws {
        let light = try #require(try VectorTileFixture.image(layers, from: tile, drawing: tile))
        let night = try #require(try VectorTileFixture.image(layers, from: tile, drawing: tile, palette: .dark))

        #expect(VectorTileFixture.image(light, has: "#F2EFE9"))
        #expect(VectorTileFixture.image(light, has: "#FFFFFF"), "the street")
        #expect(!VectorTileFixture.image(light, has: "#1C1E20"))

        #expect(VectorTileFixture.image(night, has: "#1C1E20"))
        #expect(VectorTileFixture.image(night, has: "#4D5157"), "the street's surface")
        #expect(VectorTileFixture.image(night, has: "#0E0F11"), "and its casing")
        #expect(!VectorTileFixture.image(night, has: "#F2EFE9"))
        #expect(!VectorTileFixture.image(night, has: "#FFFFFF"))
    }
}
