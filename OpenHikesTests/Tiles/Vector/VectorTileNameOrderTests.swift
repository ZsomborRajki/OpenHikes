//
//  VectorTileNameOrderTests.swift
//  OpenHikesTests
//
//  Whose name stays where two would overlap on a drawn tile, between the
//  kinds of name that are set apart: a summit's before a lake's, as
//  OpenStreetMap Carto orders the points by height ahead of every area.
//

import CoreGraphics
import Foundation
@testable import OpenHikes
import Testing

@Suite("Vector tile name order")
struct VectorTileNameOrderTests {
    private let grid = VectorTileFixture.grid
    private let tile = VectorTileAddress(z: 14, x: 8821, y: 5803)
    private let lakeInk = "#4D80B3"
    /// How far a letter's edge may be from its ink and still be the ink.
    private let inkTolerance = 24

    private var earth: VectorTileFixture.Layer {
        .init(name: "earth", features: [
            .init(
                type: .polygon,
                properties: ["kind": .string("earth")],
                geometry: VectorTileFixture.rectangle(x: 0...grid, y: 0...grid)
            ),
        ])
    }

    /// A lake's name, a little below the middle of the tile, where a name
    /// under a point at the middle stands.
    private var lake: VectorTileFixture.Layer {
        .init(name: "water", features: [
            .init(
                type: .point,
                properties: ["kind": .string("water"), "kind_detail": .string("lake"), "name": .string("Gosausee")],
                geometry: VectorTileFixture.points([(grid / 2, grid / 2 + grid / 16)])
            ),
        ])
    }

    private func point(_ properties: [String: VectorTileFixture.Value]) -> VectorTileFixture.Layer {
        .init(name: "pois", features: [
            .init(
                type: .point,
                properties: properties,
                geometry: VectorTileFixture.points([(grid / 2, grid / 2)])
            ),
        ])
    }

    private func draw(_ layers: [VectorTileFixture.Layer], at address: VectorTileAddress? = nil) throws -> CGImage {
        let drawn = address ?? tile
        return try #require(try VectorTileFixture.image([earth] + layers, from: drawn, drawing: drawn))
    }

    @Test("a lake is named where nothing has its room")
    func lakeAlone() throws {
        #expect(VectorTileFixture.image(try draw([lake]), has: lakeInk, tolerance: inkTolerance))
    }

    /// Triglav's glacier took the room of the hut beside it, and a tarn's
    /// name a summit's.
    @Test("a summit keeps its name where a lake's would cover it")
    func summitBeforeLake() throws {
        let summit = point(["kind": .string("peak"), "name": .string("Hochwanner"), "elevation": .double(2744)])

        let image = try draw([lake, summit])

        #expect(!VectorTileFixture.image(image, has: lakeInk, tolerance: inkTolerance))
    }

    /// Carto orders the areas by size ahead of every point without a
    /// height, so a lake's name still comes before a filling station's,
    /// which is written under its icon from zoom 17.
    @Test("a lake's name comes before the name of a point Carto orders by no height")
    func lakeBeforeOtherPoints() throws {
        let station = point(["kind": .string("fuel"), "name": .string("MOL Tankstelle")])
        let street = VectorTileAddress(z: 17, x: 72_491, y: 45_826)

        let image = try draw([lake, station], at: street)

        #expect(VectorTileFixture.image(image, has: lakeInk, tolerance: inkTolerance))
    }
}
