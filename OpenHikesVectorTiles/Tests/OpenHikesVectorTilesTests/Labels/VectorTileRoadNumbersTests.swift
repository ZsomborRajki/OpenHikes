//
//  VectorTileRoadNumbersTests.swift
//  OpenHikesVectorTilesTests
//
//  The numbers OpenStreetMap Carto writes along a minor road and a track
//  (`roads-text-ref-minor`), which is how a forest road is told from the
//  next, with the names of the waters the basemap files under kinds of
//  their own, and how far a path's name and a lift's stand from the line.
//

import CoreGraphics
import Foundation
@testable import OpenHikesVectorTiles
@testable import OpenHikesVectorTilesTestSupport
import Testing

@Suite("Vector tile road numbers")
struct VectorTileRoadNumbersTests {
    private typealias Category = VectorTileLabelStyle.LineCategory

    private func road(
        kind: String,
        detail: String,
        name: String? = nil,
        ref: String? = nil
    ) -> VectorTileFixture.Layer {
        var properties: [String: VectorTileFixture.Value] = ["kind": .string(kind), "kind_detail": .string(detail)]
        if let name { properties["name"] = .string(name) }
        if let ref { properties["ref"] = .string(ref) }
        let grid = VectorTileFixture.grid
        let line = VectorTileFixture.line([(0, grid / 2), (grid, grid / 2)])
        return .init(name: "roads", features: [.init(type: .line, properties: properties, geometry: line)])
    }

    private func lines(_ layer: VectorTileFixture.Layer, z: Int) throws -> [VectorTileLineLabels.NamedLine] {
        let address = VectorTileAddress(z: z, x: 0, y: 0)
        return VectorTileLineLabels.lines(
            in: try VectorTileFixture.decoded([layer]),
            source: address,
            target: address,
            language: "en"
        )
    }

    @Test("a track's number is written along it from zoom 15, the first of several")
    func trackNumbers() throws {
        let track = road(kind: "path", detail: "track", ref: "FR 4211; FR 9")

        #expect(try lines(track, z: 15).map(\.category) == [.trackNumber])
        #expect(try lines(track, z: 15).map(\.name) == ["FR 4211"])
        #expect(try lines(track, z: 14).isEmpty)
    }

    @Test("a minor road carries its name and its number, and a path or a main road no number along it")
    func whoIsNumbered() throws {
        let street = road(kind: "minor_road", detail: "unclassified", name: "Forststraße", ref: "L 12")

        #expect(Set(try lines(street, z: 16).map(\.category)) == [.minorRoad, .minorRoadNumber])
        #expect(Category.number(kind: "minor_road", detail: "residential") == .minorRoadNumber)
        #expect(Category.number(kind: "minor_road", detail: "service") == nil)
        #expect(Category.number(kind: "path", detail: "footway") == nil)
        #expect(Category.number(kind: "major_road", detail: "primary") == nil, "a main road's is on a plate")
        #expect(try lines(road(kind: "path", detail: "track", ref: " "), z: 16).isEmpty)
    }

    @Test("a number is black and slanted, and a track's stands beside the track")
    func look() {
        let track = VectorTileLabelStyle.look(of: .trackNumber)
        let street = VectorTileLabelStyle.look(of: .minorRoadNumber)

        #expect(track.face == .italic)
        #expect(track.offset(at: 16) == 5)
        #expect(street.offset(at: 16) == 0)
        #expect(track.minimumZ == 15)
        #expect(!Category.trackNumber.isPlacedAfterPoints)
    }

    @Test("a path's name stands further from its line the closer the map, and a lift's four pixels off")
    func offsets() {
        let path = VectorTileLabelStyle.look(of: .path)
        let lift = VectorTileLabelStyle.look(of: .aerialway)

        #expect(path.offset(at: 15) == 5)
        #expect(path.offset(at: 16) == 7)
        #expect(path.offset(at: 18) == 9)
        #expect(lift.offset(at: 17) == 4)
        #expect(lift.offset(at: 19) == 5)
    }

    /// The basemap files a reservoir mapped as `landuse` as a lake, and a
    /// basin and a dock under kinds of their own.
    @Test("a reservoir, a basin and a dock are named as a lake is", arguments: ["lake", "basin", "dock", "bay"])
    func waterKinds(kind: String) {
        #expect(VectorTileLabelStyle.Category.water(kind: kind, detail: nil) == .water)
        #expect(VectorTileLabelStyle.Category.water(kind: "fountain", detail: nil) == nil)
    }
}
