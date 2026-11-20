//
//  VectorTileAreaDetailsTests.swift
//  OpenHikesTests
//
//  What the vector extras say of the basemap's areas, joined by the id each
//  archive gives a feature: the id read off the wire, a wood's leaves found
//  by it, and the extras' schema writing the id the way the basemap does.
//

import CoreGraphics
import Foundation
@testable import OpenHikes
import Testing

@Suite("Vector tile area details")
struct VectorTileAreaDetailsTests {
    private let grid = VectorTileFixture.grid
    /// The basemap's id for way 91938915: a 2 for a way above bit 44, and
    /// for relation 91938915, a 3.
    private let way: UInt64 = 35_184_464_027_747
    private let relation: UInt64 = 52_776_650_072_163

    private func area(
        _ kind: String?,
        detail: String? = nil,
        id: UInt64? = nil
    ) -> VectorTileFixture.Feature {
        var properties: [String: VectorTileFixture.Value] = [:]
        if let kind { properties["kind"] = .string(kind) }
        if let detail { properties["kind_detail"] = .string(detail) }
        return .init(
            type: .polygon,
            properties: properties,
            geometry: VectorTileFixture.rectangle(x: 0...grid, y: 0...grid),
            id: id
        )
    }

    private func decoded(
        landuse: [VectorTileFixture.Feature],
        details: [VectorTileFixture.Feature]
    ) throws -> MapboxVectorTile {
        try VectorTileFixture.decoded([
            .init(name: "landuse", features: landuse),
            .init(name: VectorTileAreaDetails.layerName, features: details),
        ])
    }

    @Test("a feature's id is read off the wire, and one without is without")
    func idsAreRead() throws {
        let tile = try decoded(landuse: [area("wood", id: way), area("scrub")], details: [])
        let features = try #require(tile.layers["landuse"]?.features)

        #expect(features.map(\.id) == [way, nil])
    }

    @Test("an area's detail is what the extras say of its id")
    func detailById() throws {
        let tile = try decoded(
            landuse: [area("wood", id: way), area("wood", id: relation), area("wood")],
            details: [area(nil, detail: "needleleaved", id: way)]
        )
        let details = VectorTileAreaDetails(tile)
        let woods = try #require(tile.layers["landuse"]?.features)

        #expect(details.detail(of: woods[0]) == "needleleaved")
        #expect(details.detail(of: woods[1]) == nil, "a relation of the same number is another thing")
        #expect(details.detail(of: woods[2]) == nil, "an area with no id is nobody's")
    }

    /// The extras' own areas — a grave yard, a shoal — carry theirs.
    @Test("an area's own detail comes before the extras' word for its id")
    func ownDetailFirst() throws {
        let tile = try decoded(
            landuse: [area("grave_yard", detail: "jewish", id: way)],
            details: [area(nil, detail: "christian", id: way)]
        )
        let yard = try #require(tile.layers["landuse"]?.features.first)

        #expect(VectorTileAreaDetails(tile).detail(of: yard) == "jewish")
    }

    @Test("a tile with no extras has no details, and a detail with no id or no value is passed over")
    func nothingToSay() throws {
        let bare = try VectorTileFixture.decoded([.init(name: "landuse", features: [area("wood", id: way)])])
        let wood = try #require(bare.layers["landuse"]?.features.first)
        #expect(VectorTileAreaDetails(bare).detail(of: wood) == nil)

        let odd = try decoded(
            landuse: [area("wood", id: way)],
            details: [area(nil, detail: "mixed"), area(nil, id: way)]
        )
        #expect(VectorTileAreaDetails(odd).detail(of: wood) == nil)
    }

    // MARK: A boundary filed as a forest

    /// Relation 91938915 and way 91938915 as the extras' own layers name
    /// them: Planetiler's id for an element, ten times OpenStreetMap's plus
    /// 3 for a relation or 2 for a way.
    private let outlinedRelation: UInt64 = 919_389_153
    private let outlinedWay: UInt64 = 919_389_152

    private func decoded(
        forests: [VectorTileFixture.Feature],
        outlined ids: [UInt64]
    ) throws -> MapboxVectorTile {
        try VectorTileFixture.decoded([
            .init(name: "landuse", features: forests),
            .init(
                name: VectorTileRasterizer.protectedAreasLayer,
                features: ids.map { area("protected_area", id: $0) }
            ),
        ])
    }

    /// The basemap files a United States National Forest's boundary under
    /// the kind of a mapped forest; the extras outline the same relation.
    @Test("a forest whose element the extras outline as protected is that area's boundary")
    func boundaryFiledAsForest() throws {
        let tile = try decoded(
            forests: [
                area("forest", id: relation), area("forest", id: way),
                area("wood", id: relation), area("forest"),
            ],
            outlined: [outlinedRelation]
        )
        let details = VectorTileAreaDetails(tile)
        let areas = try #require(tile.layers["landuse"]?.features)

        #expect(details.isBoundary(areas[0]))
        #expect(!details.isBoundary(areas[1]), "a way of the same number is another thing")
        #expect(!details.isBoundary(areas[2]), "only a forest is filed so")
        #expect(!details.isBoundary(areas[3]), "an area with no id is nobody's")
    }

    @Test("on a tile with no such outline, a forest is a forest")
    func forestWithNoOutline() throws {
        let tile = try decoded(forests: [area("forest", id: relation)], outlined: [outlinedWay])
        let forest = try #require(tile.layers["landuse"]?.features.first)

        #expect(!VectorTileAreaDetails(tile).isBoundary(forest))
    }

    @Test("the id Planetiler gives an element reads as the basemap's for it")
    func extrasIDs() {
        #expect(VectorTileAreaDetails.basemapID(ofExtras: outlinedRelation) == relation)
        #expect(VectorTileAreaDetails.basemapID(ofExtras: outlinedWay) == way)
        #expect(VectorTileAreaDetails.basemapID(ofExtras: outlinedWay - 2) == nil, "no element is of type 0")
    }

    // MARK: The extras' schema

    /// A protected area is matched by the id Planetiler gives a feature the
    /// schema gives none, so its layer has to go on giving none.
    @Test("the extras give a protected area's outline no id of their own")
    func schemaLeavesTheOutlinesId() throws {
        let schema = try String(
            contentsOf: StringCatalogTests.sourceRoot.appending(path: "Scripts/lib/vector-extras.yml"),
            encoding: .utf8
        )
        let layer = try #require(
            schema.components(separatedBy: "- id: \(VectorTileRasterizer.protectedAreasLayer)\n").last
        )
        .components(separatedBy: "\n- id: ")[0]

        #expect(layer.contains("boundary: protected_area"))
        #expect(!layer.contains("\n    id:"))
    }

    /// The join is only as good as the two archives agreeing on an id. The
    /// basemap's is the OpenStreetMap id with 2 for a way or 3 for a relation
    /// above bit 44, which the extras' schema has to write the same way.
    @Test("the extras write an area's id as the basemap does")
    func schemaWritesTheBasemapsId() throws {
        let schema = try String(
            contentsOf: StringCatalogTests.sourceRoot.appending(path: "Scripts/lib/vector-extras.yml"),
            encoding: .utf8
        )
        let typeShift: UInt64 = 44
        let wayBase = UInt64(2) << typeShift
        let relationBase = UInt64(3) << typeShift

        #expect(schema.contains(
            #"'${ (feature.osm_type == "relation" ? \#(relationBase) : \#(wayBase)) + feature.id }'"#
        ))
        #expect(way == wayBase + (relation - relationBase))
    }

    @Test("every detail the extras keep of a wood, a wetland or a beach picks a pattern of its own")
    func schemaDetailsAreDrawn() throws {
        let schema = try String(
            contentsOf: StringCatalogTests.sourceRoot.appending(path: "Scripts/lib/vector-extras.yml"),
            encoding: .utf8
        )
        let layer = try #require(schema.components(separatedBy: "- id: \(VectorTileAreaDetails.layerName)\n").last)
            .components(separatedBy: "\n- id: ")[0]
        let values = { (key: String) -> [String] in
            let line = layer.split(separator: "\n").first { $0.contains("- \(key): [") } ?? ""
            let list = line.split(separator: "[").last?.split(separator: "]").first ?? ""
            return list.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        let plain = VectorTilePatterns.symbols(kind: "wood", detail: nil, z: VectorTilePatterns.firstZ)

        #expect(values("leaf_type").count == 4)
        for leaves in values("leaf_type") {
            #expect(VectorTilePatterns.symbols(kind: "wood", detail: leaves, z: VectorTilePatterns.firstZ) != plain)
        }
        #expect(values("wetland").count > 8)
        for wetland in values("wetland") {
            let isFilled = VectorTileStyle.wetlandFill(detail: wetland) != nil
            #expect(isFilled || VectorTileStyle.isMud(kind: "wetland", detail: wetland), "\(wetland)")
        }
        #expect(values("surface").count > 4)
        for surface in values("surface") {
            #expect(VectorTilePatterns.symbols(kind: "beach", detail: surface, z: VectorTilePatterns.firstZ) != nil)
        }
        for religion in values("religion") {
            let graves = VectorTilePatterns.ground(kind: "cemetery", detail: religion, z: VectorTilePatterns.firstZ)
            #expect(graves != VectorTilePatterns.ground(kind: "cemetery", detail: nil, z: VectorTilePatterns.firstZ))
        }
    }
}
