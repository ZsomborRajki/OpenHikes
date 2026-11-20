//
//  MapboxVectorTileTests.swift
//  OpenHikesTests
//
//  The vector tile reader against tiles written by `VectorTileFixture`: what
//  it keeps, what it passes over, every kind of value the spec allows, and
//  geometry read back to the points it was written from.
//

import CoreGraphics
import Foundation
@testable import OpenHikes
import Testing

@Suite("Mapbox vector tile")
struct MapboxVectorTileTests {
    private let everything: Set<String> = ["earth", "roads", "pois", "kind", "kind_detail", "name", "count"]

    @Test("layers come back with their extent, features, types and properties")
    func readsLayersAndFeatures() throws {
        let data = VectorTileFixture.data([
            .init(name: "earth", extent: 512, features: [
                .init(
                    type: .polygon,
                    properties: ["kind": .string("earth")],
                    geometry: VectorTileFixture.rectangle(x: 0...512, y: 0...512)
                ),
            ]),
            .init(name: "roads", features: [
                .init(
                    type: .line,
                    properties: ["kind": .string("path"), "kind_detail": .string("track")],
                    geometry: VectorTileFixture.line([(0, 0), (100, 100)])
                ),
                .init(
                    type: .line,
                    properties: ["kind": .string("minor_road")],
                    geometry: VectorTileFixture.line([(5, 5), (9, 9)])
                ),
            ]),
        ])

        let tile = try MapboxVectorTile(data: data, layerNames: everything, propertyKeys: everything)

        #expect(Set(tile.layers.keys) == ["earth", "roads"])
        #expect(tile.layers["earth"]?.extent == 512)
        #expect(
            tile.layers["roads"]?.extent == MapboxVectorTile.defaultExtent,
            "a layer that names no extent has the spec's"
        )
        let roads = try #require(tile.layers["roads"]?.features)
        #expect(roads.map(\.type) == [.line, .line])
        #expect(roads[0].string("kind") == "path")
        #expect(roads[0].string("kind_detail") == "track")
        #expect(roads[1].string("kind_detail") == nil)
    }

    /// The rasterizer reads a few layers and keys of a tile that carries a
    /// thousand points of interest; the rest is never decoded.
    @Test("only the layers and property keys asked for are kept")
    func keepsWhatItIsAskedFor() throws {
        let data = VectorTileFixture.data([
            .init(name: "pois", features: [
                .init(
                    type: .point,
                    properties: ["kind": .string("bench"), "name": .string("Rest")],
                    geometry: VectorTileFixture.points([(1, 1)])
                ),
            ]),
            .init(name: "places", features: [
                .init(
                    type: .point,
                    properties: ["kind": .string("locality")],
                    geometry: VectorTileFixture.points([(2, 2)])
                ),
            ]),
        ])

        let tile = try MapboxVectorTile(data: data, layerNames: ["pois"], propertyKeys: ["kind"])

        #expect(Set(tile.layers.keys) == ["pois"])
        let bench = try #require(tile.layers["pois"]?.features.first)
        #expect(bench.properties == ["kind": .string("bench")], "the name was not asked for")
    }

    @Test("every value kind the spec allows is read")
    func readsEveryValueKind() throws {
        let properties: [String: VectorTileFixture.Value] = [
            "a_string": .string("ü"),
            "b_double": .double(1.25),
            "c_float": .float(0.5),
            "d_int": .int(-3),
            "e_uint": .uint(42),
            "f_sint": .sint(-7),
            "g_bool": .bool(true),
        ]
        let data = VectorTileFixture.data([
            .init(name: "pois", features: [
                .init(type: .point, properties: properties, geometry: VectorTileFixture.points([(0, 0)])),
            ]),
        ])

        let tile = try MapboxVectorTile(data: data, layerNames: ["pois"], propertyKeys: Set(properties.keys))
        let feature = try #require(tile.layers["pois"]?.features.first)

        #expect(feature.string("a_string") == "ü")
        #expect(feature.number("b_double") == 1.25)
        #expect(feature.number("c_float") == 0.5)
        #expect(feature.number("d_int") == -3)
        #expect(feature.number("e_uint") == 42)
        #expect(feature.number("f_sint") == -7)
        #expect(feature.flag("g_bool"))
        #expect(!feature.flag("missing"))
    }

    @Test("a tile cut short is refused, not read as far as it goes")
    func truncatedTileThrows() {
        let data = VectorTileFixture.data([
            .init(name: "roads", features: [
                .init(
                    type: .line,
                    properties: ["kind": .string("path")],
                    geometry: VectorTileFixture.line([(0, 0), (9, 9)])
                ),
            ]),
        ])

        #expect(throws: MapboxVectorTile.DecodingError.self) {
            try MapboxVectorTile(data: data.prefix(data.count - 3), layerNames: ["roads"], propertyKeys: ["kind"])
        }
    }

    @Test("a body that is not a tile is refused")
    func htmlIsRefused() {
        #expect(throws: MapboxVectorTile.DecodingError.self) {
            try MapboxVectorTile(data: Data("<html>Rate limited</html>".utf8), layerNames: ["roads"], propertyKeys: [])
        }
    }

    /// Steps are zigzag deltas from a cursor that carries across the parts of
    /// a feature, so a step back left or up must come out negative.
    @Test("geometry reads back to the points it was written from, steps back included")
    func geometryReadsBack() throws {
        let data = VectorTileFixture.data([
            .init(name: "pois", extent: 512, features: [
                .init(type: .point, properties: [:], geometry: VectorTileFixture.points([(10, 20), (5, 3), (300, 2)])),
            ]),
        ])
        let tile = try MapboxVectorTile(data: data, layerNames: ["pois"], propertyKeys: [])
        let feature = try #require(tile.layers["pois"]?.features.first)
        // A 512 grid drawn at its own zoom onto a 512-pixel picture: one pixel a unit.
        let geometry = VectorTileGeometry(
            extent: 512,
            source: VectorTileAddress(z: 3, x: 1, y: 2),
            target: VectorTileAddress(z: 3, x: 1, y: 2)
        )

        #expect(geometry.points(of: feature) == [CGPoint(x: 10, y: 20), CGPoint(x: 5, y: 3), CGPoint(x: 300, y: 2)])
    }

    /// The vector extras are a second archive cut on the same grid, drawn
    /// into the basemap's tile: their points join its `pois`, and a layer of
    /// their own comes along whole.
    @Test("a tile merged with another keeps its own features first and takes the other's after")
    func merging() throws {
        let point = { (kind: String) in
            VectorTileFixture.Feature(
                type: .point,
                properties: ["kind": .string(kind)],
                geometry: VectorTileFixture.points([(10, 10)])
            )
        }
        let wall = VectorTileFixture.Feature(
            type: .line,
            properties: ["kind": .string("fence")],
            geometry: VectorTileFixture.line([(0, 0), (100, 0)])
        )
        let names = everything.union(["barriers"])
        let basemap = try MapboxVectorTile(
            data: VectorTileFixture.data([.init(name: "pois", features: [point("peak")])]),
            layerNames: names,
            propertyKeys: names
        )
        let extras = try MapboxVectorTile(
            data: VectorTileFixture.data([
                .init(name: "pois", features: [point("gate")]),
                .init(name: "barriers", features: [wall]),
            ]),
            layerNames: names,
            propertyKeys: names
        )

        let merged = basemap.merging(extras)

        #expect(merged.layers["pois"]?.features.map { $0.string("kind") } == ["peak", "gate"])
        #expect(merged.layers["barriers"]?.features.count == 1)
        #expect(merged.layers["pois"]?.features.map(\.isFromExtras) == [false, true], "each says which archive gave it")
        #expect(merged.layers["barriers"]?.features.map(\.isFromExtras) == [true])
        #expect(basemap.layers["pois"]?.features.map(\.isFromExtras) == [false])
    }

    @Test("a layer on another grid is not merged into one it would misplace")
    func mergingKeepsItsGrid() throws {
        let feature = VectorTileFixture.Feature(
            type: .point,
            properties: ["kind": .string("gate")],
            geometry: VectorTileFixture.points([(10, 10)])
        )
        let basemap = try MapboxVectorTile(
            data: VectorTileFixture.data([.init(name: "pois", features: [feature])]),
            layerNames: everything,
            propertyKeys: everything
        )
        let other = try MapboxVectorTile(
            data: VectorTileFixture.data([.init(name: "pois", extent: 512, features: [feature])]),
            layerNames: everything,
            propertyKeys: everything
        )

        #expect(basemap.merging(other).layers["pois"]?.features.count == 1)
    }
}
