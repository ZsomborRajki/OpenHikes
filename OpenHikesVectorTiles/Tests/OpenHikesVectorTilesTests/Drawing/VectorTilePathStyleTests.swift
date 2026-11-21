//
//  VectorTilePathStyleTests.swift
//  OpenHikesVectorTilesTests
//
//  What a path is drawn as: OpenStreetMap Carto's figures for a footway, a
//  cycleway, a bridleway, a track and a flight of steps (`roads.mss`), which
//  change with the zoom, the surface, a track's grade and whether the way is
//  closed to those it is for; and what each archive can say of a path.
//

import CoreGraphics
import Foundation
@testable import OpenHikesVectorTiles
import RealModule
import Testing

@Suite("Vector tile path style")
struct VectorTilePathStyleTests {
    private typealias Traits = VectorTileStyle.PathTraits

    private func look(_ traits: Traits, z: Int) -> VectorTileStyle.PathLook? {
        VectorTileStyle.path(traits, z: z)
    }

    @Test("an open path is drawn from Carto's zoom for its kind, and a closed one from 15", arguments: [
        (VectorTileStyle.PathKind.footway, 14), (.steps, 14), (.cycleway, 13), (.bridleway, 13), (.track, 13),
    ])
    func firstZooms(kind: VectorTileStyle.PathKind, firstZ: Int) {
        #expect(look(Traits(kind: kind), z: firstZ - 1) == nil)
        #expect(look(Traits(kind: kind), z: firstZ) != nil)
        #expect(look(Traits(kind: kind, isClosed: true), z: 14) == nil)
        #expect(look(Traits(kind: kind, isClosed: true), z: 15) != nil)
    }

    @Test("a closed path is its kind's paler color")
    func closedColors() throws {
        for kind in VectorTileStyle.PathKind.allCases {
            let open = try #require(look(Traits(kind: kind), z: 16))
            let closed = try #require(look(Traits(kind: kind, isClosed: true), z: 16))
            #expect(open.color != closed.color)
            #expect(open.width == closed.width)
            #expect(open.dash == closed.dash)
        }
    }

    @Test("a footpath's dashes say what it is made of, from zoom 15")
    func surfaces() throws {
        let unknown = Traits(kind: .footway)
        let paved = Traits(kind: .footway, surface: .paved)
        let unpaved = Traits(kind: .footway, surface: .unpaved)

        #expect(try #require(look(paved, z: 14)).dash == [1, 3], "one look until zoom 15")
        #expect(try #require(look(unknown, z: 14)).dash == [1, 3])
        #expect(try #require(look(unknown, z: 15)).dash == [1, 3, 2, 4])
        #expect(try #require(look(unknown, z: 16)).dash == [1, 4, 2, 3])
        #expect(try #require(look(unpaved, z: 16)).dash == [1, 4])
        #expect(try #require(look(paved, z: 15)).dash.first == 2)
        #expect(try #require(look(paved, z: 16)).dash.first == 3)
        #expect(try #require(look(paved, z: 17)).dash == [3, 3])
        #expect(try #require(look(Traits(kind: .cycleway, surface: .unpaved), z: 16)).dash == [1, 4])
    }

    @Test("a footpath widens by Carto's steps, and a cycleway by its own")
    func widths() throws {
        let footway = { (z: Int) in try #require(look(Traits(kind: .footway), z: z)).width }
        let cycleway = { (z: Int) in try #require(look(Traits(kind: .cycleway), z: z)).width }

        #expect(try footway(14).isApproximatelyEqual(to: 0.7, absoluteTolerance: 0.001))
        #expect(try footway(15) == 1)
        #expect(try footway(16).isApproximatelyEqual(to: 1.3, absoluteTolerance: 0.001))
        #expect(try footway(18).isApproximatelyEqual(to: 1.3, absoluteTolerance: 0.001))
        #expect(try footway(19).isApproximatelyEqual(to: 1.6, absoluteTolerance: 0.001))
        #expect(try footway(20).isApproximatelyEqual(to: 1.6, absoluteTolerance: 0.001))
        #expect(try cycleway(13).isApproximatelyEqual(to: 0.7, absoluteTolerance: 0.001))
        #expect(try cycleway(18) == 1)
    }

    @Test("a track's line is the more broken the softer its grade, and unbroken for the firmest")
    func trackGrades() throws {
        let dash = { (grade: Int?, z: Int) in try #require(look(Traits(kind: .track, grade: grade), z: z)).dash }

        #expect(try dash(nil, 15) == [5, 4, 2, 4])
        #expect(try dash(1, 15).isEmpty)
        #expect(try dash(2, 15) == [11, 4])
        #expect(try dash(3, 15) == [7, 5])
        #expect(try dash(4, 15) == [4, 6])
        #expect(try dash(5, 15) == [2, 8])
        #expect(try dash(1, 13).isEmpty)
        // Shorter before zoom 15, where the track is a third as wide.
        for grade in 2...5 {
            let far = try dash(grade, 13)
            let near = try dash(grade, 15)
            #expect(far.count == 2)
            #expect(far[0] < near[0])
        }
        #expect(try #require(look(Traits(kind: .track), z: 15)).alpha < 1)
    }

    /// The band is a pixel wider than the path either side, and a bridge's
    /// casing and a tunnel's stand outside it.
    @Test("the band under a path is wider than the path, and a bridge's casing wider than the band")
    func bands() throws {
        let path = try #require(look(Traits(kind: .footway), z: 16))
        #expect(path.bandWidth == path.width + 2)
        #expect(path.bridgeCasingWidth == path.bandWidth + 1)
        #expect(path.tunnelCasingWidth == path.bandWidth + 2)

        // Carto narrows the band of the two firmest grades, drawn heavier.
        let soft = try #require(look(Traits(kind: .track, grade: 4), z: 15))
        let firm = try #require(look(Traits(kind: .track, grade: 1), z: 15))
        #expect(firm.width == soft.width)
        #expect(firm.bandWidth < soft.bandWidth)
    }

    @Test("a track's grade is read out of its tracktype, and nothing else is one")
    func grades() {
        #expect(VectorTileStyle.trackGrade("grade1") == 1)
        #expect(VectorTileStyle.trackGrade("grade5") == 5)
        #expect(VectorTileStyle.trackGrade("grade6") == nil)
        #expect(VectorTileStyle.trackGrade("solid") == nil)
        #expect(VectorTileStyle.trackGrade(nil) == nil)
    }

    // MARK: What each archive says

    @Test("the basemap's path is its detail's kind, closed where its access closes it")
    func basemapPaths() {
        #expect(VectorTileStyle.pathTraits(detail: "track", access: nil) == Traits(kind: .track))
        #expect(VectorTileStyle.pathTraits(detail: "path", access: nil) == Traits(kind: .footway))
        #expect(VectorTileStyle.pathTraits(detail: "footway", access: "yes") == Traits(kind: .footway))
        #expect(VectorTileStyle.pathTraits(detail: "steps", access: "private") == Traits(kind: .steps, isClosed: true))
        #expect(VectorTileStyle.pathTraits(detail: "cycleway", access: "no")?.isClosed == true)
        // A detail the basemap makes up of another tag is still somebody's path.
        #expect(VectorTileStyle.pathTraits(detail: "emergency_access", access: nil) == Traits(kind: .footway))
    }

    @Test("a pedestrian street, a pier, a platform and a corridor are no paths", arguments: [
        "pedestrian", "pier", "platform", "corridor",
    ])
    func notPaths(detail: String) {
        #expect(VectorTileStyle.pathTraits(detail: detail, access: nil) == nil)
        #expect(VectorTileStyle.pathTraits(detail: nil, access: nil) == nil)
    }

    @Test("the extras' path says its kind, its surface, its grade and whether it is closed")
    func extrasPaths() {
        #expect(
            VectorTileStyle.pathTraits(kind: "track", surface: nil, tracktype: "grade3", access: nil)
                == Traits(kind: .track, grade: 3)
        )
        #expect(
            VectorTileStyle.pathTraits(kind: "footway", surface: "unpaved", tracktype: nil, access: "no")
                == Traits(kind: .footway, surface: .unpaved, isClosed: true)
        )
        #expect(
            VectorTileStyle.pathTraits(kind: "cycleway", surface: "paved", tracktype: nil, access: nil)?.surface
                == .paved
        )
        #expect(VectorTileStyle.pathTraits(kind: "towpath", surface: nil, tracktype: nil, access: nil) == nil)
        #expect(VectorTileStyle.pathTraits(kind: nil, surface: nil, tracktype: nil, access: nil) == nil)
    }

    // MARK: The extras' schema

    private func layer(_ id: String) throws -> String {
        let schema = try String(
            contentsOf: Checkout.extrasSchema,
            encoding: .utf8
        )
        return try #require(schema.components(separatedBy: "\n- id: \(id)\n").last)
            .components(separatedBy: "\n- id: ")[0]
    }

    /// The map draws a tile's paths from the extras alone where it has
    /// them, so a kind written there and unknown here would be a path lost.
    @Test("every kind of path the extras write is one the map draws")
    func schemaKinds() throws {
        let paths = try layer(VectorTileRasterizer.pathsLayer)
        let kinds = paths.split(separator: "\n")
            .drop { !$0.contains("key: kind") }
            .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("value: ") }
            .map { $0.trimmingCharacters(in: .whitespaces).dropFirst("value: ".count) }
            .filter { !["'no'", "paved", "unpaved", "true"].contains($0) }

        #expect(Set(kinds.map(String.init)) == Set(VectorTileStyle.PathKind.allCases.map(\.rawValue)))
    }

    @Test("the extras keep a service road's service only where Carto draws it as a minor one")
    func schemaMinorServices() throws {
        let service = try layer(VectorTileRasterizer.serviceRoadsLayer)
        for minor in VectorTileStyle.minorServices {
            #expect(service.contains(minor))
        }
        #expect(service.contains("tag_value: service"))
    }
}
