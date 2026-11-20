//
//  VectorTileWaysDrawingTests.swift
//  OpenHikesTests
//
//  What a drawn tile shows of the ways the vector extras give again, from
//  tiles written by `VectorTileFixture`: the paths and the service roads
//  drawn from the extras in place of the basemap's, the band under a path
//  and the casing round its bridge, a road being built, the towers of a
//  power line, and beside them a glacier's edge, a waterway through a
//  culvert, a bridge mapped as an area and a secondary road from far off.
//

import CoreGraphics
import Foundation
@testable import OpenHikes
import Testing

@Suite("Vector tile ways")
struct VectorTileWaysDrawingTests {
    private let grid = VectorTileFixture.grid
    private let land = VectorTileFixture.color("#F2EFE9")

    private var earth: VectorTileFixture.Layer {
        .init(name: "earth", features: [
            .init(
                type: .polygon,
                properties: ["kind": .string("earth")],
                geometry: VectorTileFixture.rectangle(x: 0...grid, y: 0...grid)
            ),
        ])
    }

    /// Round the left of a line across the middle, and round the top of one
    /// down it: each clear of the other line.
    private var onTheLineAcross: CGRect {
        VectorTileFixture.pixels(x: (grid / 8)...(grid / 4), y: (grid * 7 / 16)...(grid * 9 / 16))
    }

    private var onTheLineDown: CGRect {
        VectorTileFixture.pixels(x: (grid * 7 / 16)...(grid * 9 / 16), y: (grid / 8)...(grid / 4))
    }

    private func way(across: Bool, _ properties: [String: VectorTileFixture.Value]) -> VectorTileFixture.Feature {
        let ends = [-grid / 4, grid + grid / 4].map { across ? ($0, grid / 2) : (grid / 2, $0) }
        return .init(type: .line, properties: properties, geometry: VectorTileFixture.line(ends))
    }

    private func draw(_ layers: [VectorTileFixture.Layer], z: Int) throws -> CGImage {
        let tile = VectorTileAddress(z: z, x: 1 << (z - 1), y: 1 << (z - 1))
        return try #require(try VectorTileFixture.image([earth] + layers, from: tile, drawing: tile))
    }

    private func isLand(_ image: CGImage, _ rect: CGRect) -> Bool {
        VectorTileFixture.colors(of: image, in: rect) == [land]
    }

    // MARK: Paths

    private var basemapFootpath: VectorTileFixture.Layer {
        .init(name: "roads", features: [
            way(across: true, ["kind": .string("path"), "kind_detail": .string("footway")]),
        ])
    }

    @Test("a tile's paths are drawn from the extras where it has them, and none of the basemap's")
    func extrasPathsStandIn() throws {
        let track = VectorTileFixture.Layer(name: VectorTileRasterizer.pathsLayer, features: [
            way(across: false, ["kind": .string("track"), "tracktype": .string("grade1")]),
        ])

        let alone = try draw([basemapFootpath], z: 16)
        let both = try draw([basemapFootpath, track], z: 16)

        #expect(!isLand(alone, onTheLineAcross), "with no extras the basemap's path is drawn")
        #expect(isLand(both, onTheLineAcross))
        #expect(!isLand(both, onTheLineDown))
    }

    /// White at four tenths over the land, which only the band is.
    @Test("a path lies on Carto's pale band from zoom 15")
    func band() throws {
        let band = "#F7F5F2"
        #expect(VectorTileFixture.image(try draw([basemapFootpath], z: 16), has: band))
        #expect(!VectorTileFixture.image(try draw([basemapFootpath], z: 14), has: band))
    }

    @Test("a path's bridge is cased in black, and a path on the ground is not")
    func bridge() throws {
        let steps: [String: VectorTileFixture.Value] = ["kind": .string("path"), "kind_detail": .string("steps")]
        var bridged = steps
        bridged["is_bridge"] = .bool(true)

        let onTheGround = try draw([.init(name: "roads", features: [way(across: true, steps)])], z: 16)
        let onABridge = try draw([.init(name: "roads", features: [way(across: true, bridged)])], z: 16)

        #expect(!VectorTileFixture.image(onTheGround, has: "#000000"))
        #expect(VectorTileFixture.image(onABridge, has: "#000000"))
        #expect(VectorTileFixture.image(onABridge, has: "#FFFFFF"), "its band is solid")
    }

    // MARK: Service roads

    @Test("service roads are the extras' where a tile has them: a driveway waits for zoom 16, the rest do not")
    func serviceRoads() throws {
        let basemap = VectorTileFixture.Layer(name: "roads", features: [
            way(across: true, ["kind": .string("minor_road"), "kind_detail": .string("service")]),
        ])
        let driveway = VectorTileFixture.Layer(name: VectorTileRasterizer.serviceRoadsLayer, features: [
            way(across: false, ["service": .string("driveway")]),
        ])
        let lane = VectorTileFixture.Layer(name: VectorTileRasterizer.serviceRoadsLayer, features: [
            way(across: false, [:]),
        ])

        #expect(!isLand(try draw([basemap], z: 15), onTheLineAcross))
        let withDriveway = try draw([basemap, driveway], z: 15)
        #expect(isLand(withDriveway, onTheLineAcross), "the basemap's is left out")
        #expect(isLand(withDriveway, onTheLineDown), "and a driveway is not drawn yet")
        #expect(!isLand(try draw([basemap, driveway], z: 16), onTheLineDown))
        #expect(!isLand(try draw([basemap, lane], z: 15), onTheLineDown))
        #expect(isLand(try draw([basemap], z: 13), onTheLineAcross), "Carto draws no service road before zoom 14")
    }

    // MARK: Roads being built, and power lines

    @Test("a road being built is its road's color with white dashes down it")
    func construction() throws {
        let layer = VectorTileFixture.Layer(name: VectorTileRasterizer.constructionLayer, features: [
            way(across: true, ["kind": .string("primary")]),
        ])
        let image = try draw([layer], z: 14)

        #expect(VectorTileFixture.image(image, has: "#FCD6A4"))
        #expect(VectorTileFixture.image(image, has: "#FFFFFF"))
        #expect(VectorTileStyle.construction(kind: "primary", z: 11) == nil)
        #expect(VectorTileStyle.construction(kind: "residential", z: 13) == nil)
        #expect(VectorTileStyle.construction(kind: "residential", z: 14) != nil)
        #expect(VectorTileStyle.construction(kind: "footway", z: 16) == nil)
    }

    @Test("a power line's tower is a gray square from zoom 14, and a pole one from 16")
    func powerPoints() throws {
        let point = { (kind: String) in
            VectorTileFixture.Layer(name: VectorTileRasterizer.powerPointsLayer, features: [
                .init(
                    type: .point,
                    properties: ["kind": .string(kind)],
                    geometry: VectorTileFixture.points([(grid / 2, grid / 2)])
                ),
            ])
        }

        #expect(VectorTileFixture.image(try draw([point("tower")], z: 15), has: "#868686"))
        #expect(!VectorTileFixture.image(try draw([point("tower")], z: 13), has: "#868686"))
        #expect(VectorTileFixture.image(try draw([point("pole")], z: 16), has: "#928F8F"))
        #expect(!VectorTileFixture.image(try draw([point("pole")], z: 15), has: "#928F8F"))
    }

    // MARK: The basemap's own

    @Test("a glacier has its pale blue edge")
    func glacierEdge() throws {
        let glacier = VectorTileFixture.Layer(name: "landuse", features: [
            .init(
                type: .polygon,
                properties: ["kind": .string("glacier")],
                geometry: VectorTileFixture.rectangle(x: (grid / 4)...(grid * 3 / 4), y: (grid / 4)...(grid * 3 / 4))
            ),
        ])

        #expect(VectorTileFixture.image(try draw([glacier], z: 9), has: "#99CCFF"))
        #expect(VectorTileFixture.image(try draw([glacier], z: 9), has: "#DDECEC"))
    }

    @Test("a river through a culvert is pale between its dashes, from zoom 12")
    func waterTunnel() throws {
        let river: [String: VectorTileFixture.Value] = ["kind": .string("river")]
        var culvert = river
        culvert["tunnel"] = .string("culvert")
        var bridge = river
        bridge["tunnel"] = .string("no")
        let layer = { (properties: [String: VectorTileFixture.Value]) in
            VectorTileFixture.Layer(name: "water", features: [way(across: true, properties)])
        }

        #expect(VectorTileFixture.image(try draw([layer(culvert)], z: 14), has: "#F3F7F7"))
        #expect(!VectorTileFixture.image(try draw([layer(river)], z: 14), has: "#F3F7F7"))
        #expect(!VectorTileFixture.image(try draw([layer(bridge)], z: 14), has: "#F3F7F7"))
        #expect(VectorTileStyle.waterTunnel(kind: "river", z: 11) == nil)
        #expect(VectorTileStyle.waterTunnel(kind: "stream", z: 13) == nil)
        #expect(VectorTileStyle.waterTunnel(kind: "stream", z: 14) != nil)
    }

    @Test("a secondary road before zoom 12 is a gray line, and its own pale yellow from there")
    func farSecondary() throws {
        let road = VectorTileFixture.Layer(name: "roads", features: [
            way(across: true, ["kind": .string("major_road"), "kind_detail": .string("secondary")]),
        ])

        let far = try draw([road], z: 10)
        #expect(VectorTileFixture.image(far, has: "#BBBBBB"))
        #expect(!VectorTileFixture.image(far, has: "#F7FABF"))
        #expect(VectorTileFixture.image(try draw([road], z: 13), has: "#F7FABF"))
    }

    @Test("a bridge mapped as an area is Carto's gray, and the greens are each Carto's")
    func fills() {
        #expect(VectorTileStyle.landuseFills["bridge"] != nil)
        #expect(VectorTileStyle.landuseFills["bridge"] != VectorTileStyle.landuseFills["pedestrian"])
        #expect(VectorTileStyle.landuseFills["recreation_ground"] == VectorTileStyle.landuseFills["playground"])
        #expect(VectorTileStyle.landuseFills["dog_park"] == VectorTileStyle.landuseFills["playground"])
        #expect(VectorTileStyle.landuseFills["village_green"] == VectorTileStyle.landuseFills["grass"])
    }

    @Test("a border is a band with a darker line down its middle, a country's the wider")
    func borders() throws {
        let country = try #require(VectorTileStyle.boundary(kind: "country", disputed: false))
        let region = try #require(VectorTileStyle.boundary(kind: "region", disputed: false))

        #expect(country.width.value(at: 8) == 3)
        #expect(country.width.value(at: 14) == 8)
        #expect(region.width.value(at: 14) == 4)
        #expect(country.width.value(at: 10) > region.width.value(at: 10))
        #expect(try #require(country.center).width.value(at: 7) == 0, "the middle line begins at zoom 8")
        #expect(try #require(country.center).width.value(at: 10) == 1)
        #expect(try #require(region.center).width.value(at: 9) == 0)
    }
}
