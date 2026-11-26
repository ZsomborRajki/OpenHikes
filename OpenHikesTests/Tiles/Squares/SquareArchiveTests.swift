//
//  SquareArchiveTests.swift
//  OpenHikesTests
//
//  Where each set of squares is in its archive on the tile server, as the
//  app and the tool both read it: the tile a square's name is, the name a
//  tile is, the zoom each grid takes, and which archive names are asked for
//  at all.
//
//  The zooms are a storage contract, like the names: an archive already on
//  the server was packed by them, and a build that read them otherwise would
//  ask for squares that are not there.
//

import Foundation
@testable import OpenHikes
import Testing

@Suite("Square archive")
struct SquareArchiveTests {
    nonisolated static func routes(_ level: RouteSquareLevel, row: Int, column: Int) -> String {
        RouteSquareGrid.recordName(for: RouteSquare(level: level, row: row, column: column))
    }

    @Test("a square is the tile at its row and column, at its grid's zoom", arguments: [
        (SquareArchive.routing, "routing1_z12_2194_1430", SquareArchiveTile(zoom: 12, x: 2194, y: 1430)),
        (.trails, "trails1_550_796", SquareArchiveTile(zoom: 11, x: 796, y: 550)),
        (.places, "places1_137_188", SquareArchiveTile(zoom: 9, x: 188, y: 137)),
        (.routes, routes(.overview, row: 34, column: 49), SquareArchiveTile(zoom: 7, x: 49, y: 34)),
        (.routes, routes(.region, row: 137, column: 198), SquareArchiveTile(zoom: 9, x: 198, y: 137)),
        (.routes, routes(.area, row: 275, column: 398), SquareArchiveTile(zoom: 10, x: 398, y: 275)),
        (.routes, routes(.detail, row: 550, column: 796), SquareArchiveTile(zoom: 11, x: 796, y: 550)),
        (.elevation, "elevation1_339_1543", SquareArchiveTile(zoom: 12, x: 1543, y: 339)),
    ])
    func aSquareIsATile(set: SquareArchive, name: String, tile: SquareArchiveTile) {
        #expect(set.tile(named: name) == tile)
        #expect(set.name(of: tile) == name)
        #expect(set.zooms.contains(tile.zoom))
    }

    @Test("every grid's last square fits its zoom, and the hiking-routes levels take a zoom each")
    func theGridsFit() throws {
        let trails = try #require(SquareArchive.trails.tile(named: TrailCellGrid.recordName(
            for: TrailCell(row: TrailCellGrid.rowCount - 1, column: TrailCellGrid.columnCount - 1)
        )))
        #expect(trails.x < 1 << trails.zoom && trails.y < 1 << trails.zoom)
        let places = try #require(SquareArchive.places.tile(named: PlaceSquareGrid.recordName(
            for: PlaceSquare(row: PlaceSquareGrid.rowCount - 1, column: PlaceSquareGrid.columnCount - 1)
        )))
        #expect(places.x < 1 << places.zoom && places.y < 1 << places.zoom)
        var zooms: Set<Int> = []
        for level in RouteSquareLevel.shallowestFirst {
            let last = Self.routes(
                level,
                row: RouteSquareGrid.rowCount(of: level) - 1,
                column: RouteSquareGrid.columnCount(of: level) - 1
            )
            let tile = try #require(SquareArchive.routes.tile(named: last))
            #expect(tile.x < 1 << tile.zoom && tile.y < 1 << tile.zoom)
            zooms.insert(tile.zoom)
        }
        #expect(zooms == [7, 9, 10, 11])
        let elevation = try #require(SquareArchive.elevation.tile(named: ElevationSquareGrid.recordName(
            for: ElevationSquare(row: ElevationSquareGrid.rowCount - 1, column: ElevationSquareGrid.columnCount - 1)
        )))
        #expect(elevation.x < 1 << elevation.zoom && elevation.y < 1 << elevation.zoom)
        #expect(SquareArchive.routes.zooms == 7...11)
        #expect(SquareArchive.routing.zoom == 12)
        #expect(SquareArchive.trails.zoom == 11)
        #expect(SquareArchive.routes.zoom == 11)
        #expect(SquareArchive.places.zoom == 9)
        #expect(SquareArchive.elevation.zooms == 12...12)
    }

    @Test("a tile no square of the set is names none")
    func aTileThatIsNoSquare() {
        #expect(SquareArchive.trails.name(of: SquareArchiveTile(zoom: 11, x: 1440, y: 0)) == nil)
        #expect(SquareArchive.trails.name(of: SquareArchiveTile(zoom: 11, x: 0, y: 720)) == nil)
        #expect(SquareArchive.trails.name(of: SquareArchiveTile(zoom: 10, x: 0, y: 0)) == nil)
        #expect(SquareArchive.places.name(of: SquareArchiveTile(zoom: 9, x: 360, y: 0)) == nil)
        #expect(SquareArchive.routes.name(of: SquareArchiveTile(zoom: 8, x: 0, y: 0)) == nil)
        #expect(SquareArchive.routes.name(of: SquareArchiveTile(zoom: 7, x: 90, y: 0)) == nil)
        #expect(SquareArchive.routing.name(of: SquareArchiveTile(zoom: 11, x: 0, y: 0)) == nil)
        #expect(SquareArchive.elevation.name(of: SquareArchiveTile(zoom: 12, x: 2880, y: 0)) == nil)
        #expect(SquareArchive.elevation.name(of: SquareArchiveTile(zoom: 12, x: 0, y: 1440)) == nil)
    }

    @Test("a set reads no other set's names")
    func anotherSetsName() {
        let names = [
            "routing1_z12_2194_1430",
            "trails1_550_796",
            "places1_137_188",
            Self.routes(.detail, row: 550, column: 796),
            "elevation1_339_1543",
        ]
        for set in SquareArchive.allCases {
            #expect(names.filter { set.tile(named: $0) != nil }.count == 1, "\(set) reads one name")
        }
        #expect(SquareArchive.routing.tile(named: "graph1_z10_548_357") == nil)
    }

    @Test("a tile is asked for at its zoom, column and row, under the extension the server gives it")
    func aTilePath() {
        let path = SquareArchive.path(of: SquareArchiveTile(zoom: 11, x: 796, y: 550), inArchive: "trails-20261122-00")
        #expect(path == "trails-20261122-00/11/796/550.bin")
    }

    @Test("only an archive of the set's own name is asked for", arguments: [
        (SquareArchive.routing, "routing-20261122-00", true),
        (.routing, "routing", true),
        (.trails, "trails-20261122-00", true),
        (.routes, "routes-20261122-00", true),
        (.places, "places-20261122-00", true),
        (.elevation, "elevation-20261126-20", true),
        (.elevation, "routing-20261122-00", false),
        (.routing, "routes-20261122-00", false),
        (.routes, "routing-20261122-00", false),
        (.trails, "planet-20261118", false),
        (.places, "extras-20261121-00", false),
        (.routing, "routing-", false),
        (.trails, "trails--1", false),
        (.trails, "Trails-20261122-00", false),
        (.routing, "routing-../manifest", false),
        (.places, "places-2026/11", false),
        (.routes, "", false),
    ])
    func archiveNames(set: SquareArchive, name: String, isRead: Bool) {
        #expect(set.isArchiveName(name) == isRead)
    }
}
