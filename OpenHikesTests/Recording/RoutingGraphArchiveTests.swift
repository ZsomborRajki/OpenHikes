//
//  RoutingGraphArchiveTests.swift
//  OpenHikesTests
//
//  The trail graph's archive as the app and the tool both read it: a tile is
//  a region, and what a tile is called on the way. Where it is asked for,
//  and which archive names are, is ``SquareArchiveTests``'.
//

import Foundation
@testable import OpenHikes
import Testing

@Suite("Routing graph archive")
struct RoutingGraphArchiveTests {
    /// What the library looks a region up by (`Layout.routing`).
    @Test("a tile is the region itself, and nothing that is not a z12 region is one")
    func aTileIsARegion() {
        let zoom = RoutingGraphArchive.zoom
        #expect(TrailGraphSquareGrid.square(forRegionX: 2194, y: 1430, zoom: 12, squareZoom: zoom)
            == TrailGraphSquare(x: 2194, y: 1430))
        #expect(TrailGraphSquareGrid.square(forRegionX: 2194, y: 1430, zoom: 11, squareZoom: zoom) == nil)
        #expect(TrailGraphSquareGrid.square(forRegionX: 4096, y: 0, zoom: 12, squareZoom: zoom) == nil)
    }

    @Test("a tile's name reads back as the tile, and no other set's name reads as one")
    func aTileName() {
        let tile = TrailGraphSquare(x: 2194, y: 1430)
        #expect(RoutingGraphArchive.squareName(for: tile) == "routing1_z12_2194_1430")
        #expect(RoutingGraphArchive.tile(named: "routing1_z12_2194_1430") == tile)
        #expect(RoutingGraphArchive.tile(named: "graph1_z10_548_357") == nil)
        #expect(RoutingGraphArchive.tile(named: "routing1_z10_548_357") == nil)
        #expect(RoutingGraphArchive.tile(named: "routing1_z12_4096_0") == nil)
        #expect(RoutingGraphArchive.tile(named: "routing1_z12_1_2_3") == nil)
    }

    /// A tile holds every way whose box touches it, as a square of the
    /// public database's set does four levels up: the tool files by this.
    @Test("a way is filed under every z12 tile its box touches")
    func aWayAtTheTilesZoom() {
        let scale = TrailGraphSquareFile.standardCoordinateScale
        func node(_ id: Int64, _ latitude: Double, _ longitude: Double) -> TrailGraphSquareFile.Node {
            TrailGraphSquareFile.Node(
                id: id,
                latitude: Int32((latitude * Double(scale)).rounded()),
                longitude: Int32((longitude * Double(scale)).rounded())
            )
        }
        // From the region over the Königssee into the one east of it.
        let tiles = TrailGraphSquareGrid.squares(
            touching: [node(1, 47.63, 12.86), node(2, 47.63, 12.95)],
            coordinateScale: scale,
            zoom: RoutingGraphArchive.zoom
        )
        #expect(Set(tiles) == [TrailGraphSquare(x: 2194, y: 1430), TrailGraphSquare(x: 2195, y: 1430)])
    }
}
