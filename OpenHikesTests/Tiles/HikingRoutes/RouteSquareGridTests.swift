//
//  RouteSquareGridTests.swift
//  OpenHikesTests
//
//  The hiking-routes layer's squares: which level a zoom draws from, which
//  squares a box needs, and what their records are called — the names every
//  installed build will go on asking for.
//

import Foundation
@testable import OpenHikes
import Testing

@Suite("Route square grid")
struct RouteSquareGridTests {
    @Test(
        "each zoom draws from its level, and nothing is drawn shallower than zoom 7",
        arguments: [
            (6, nil), (7, RouteSquareLevel.overview), (9, .overview), (10, .region), (11, .region),
            (12, .area), (13, .area), (14, .detail), (18, .detail), (21, .detail),
        ] as [(Int, RouteSquareLevel?)]
    )
    func levelForZoom(zoom: Int, expected: RouteSquareLevel?) {
        #expect(RouteSquareLevel.level(forZoom: zoom) == expected)
    }

    @Test("the levels' squares halve or quarter as the zooms deepen, and cover the world exactly")
    func squareSides() {
        #expect(RouteSquareLevel.shallowestFirst.map(\.squareDegrees) == [4, 1, 0.5, 0.25])
        for level in RouteSquareLevel.shallowestFirst {
            #expect(Double(RouteSquareGrid.rowCount(of: level)) * level.squareDegrees == 180)
            #expect(Double(RouteSquareGrid.columnCount(of: level)) * level.squareDegrees == 360)
        }
    }

    /// The record names are a storage contract: an installed build asks for
    /// exactly these.
    @Test("a square's record name is its generation, level, row and column")
    func recordNames() {
        let square = RouteSquareGrid.square(at: .detail, latitude: 47.55, longitude: 12.98)
        #expect(RouteSquareGrid.recordName(for: square) == "routes1_z14_550_771")
        #expect(RouteSquareGrid.manifestRecordName == "routes1_manifest")
        let overview = RouteSquareGrid.square(at: .overview, latitude: 47.55, longitude: 12.98)
        #expect(RouteSquareGrid.recordName(for: overview) == "routes1_z7_34_48")
    }

    @Test("every level's names read back as the squares they name", arguments: RouteSquareLevel.shallowestFirst)
    func namesRoundTrip(level: RouteSquareLevel) {
        for (latitude, longitude) in [(47.55, 12.98), (-33.9, 151.2), (89.99, -179.99), (-90.0, 180.0)] {
            let square = RouteSquareGrid.square(at: level, latitude: latitude, longitude: longitude)
            #expect(RouteSquareGrid.square(named: RouteSquareGrid.recordName(for: square)) == square)
        }
    }

    @Test("a name that is not one of this generation's squares is refused")
    func foreignNamesAreRefused() {
        for name in [
            "routes1_manifest", "trails1_550_771", "routes2_z14_550_771", "routes1_z15_550_771",
            "routes1_z14_720_771", "routes1_z14_550_1440", "routes1_z14_-1_771", "routes1_z14_550",
        ] {
            #expect(RouteSquareGrid.square(named: name) == nil, "\(name)")
        }
    }

    @Test("a box needs every square it overlaps, and a square's bounds hold its own corner")
    func squaresCoveringABox() {
        let box = RouteSquareBounds(south: 47.4, west: 12.9, north: 47.6, east: 13.1)
        let squares = RouteSquareGrid.squares(at: .detail, covering: box)
        #expect(Set(squares.map(\.row)) == [549, 550])
        #expect(Set(squares.map(\.column)) == [771, 772])
        #expect(squares.count == 4)
        for square in squares {
            let bounds = RouteSquareGrid.bounds(of: square)
            #expect(RouteSquareGrid.square(at: .detail, latitude: bounds.south, longitude: bounds.west) == square)
        }
    }

    @Test("a box that is not one needs nothing")
    func invalidBoxes() {
        #expect(RouteSquareGrid.squares(
            at: .area,
            covering: RouteSquareBounds(south: 48, west: 12, north: 47, east: 13)
        ).isEmpty)
        #expect(RouteSquareGrid.squares(
            at: .area,
            covering: RouteSquareBounds(south: .nan, west: 12, north: 47, east: 13)
        ).isEmpty)
    }

    @Test("networks order from local to international, with the untagged least of all")
    func networkOrder() {
        #expect(RouteNetwork(tag: "iwn") == .international)
        #expect(RouteNetwork(tag: "nwn") == .national)
        #expect(RouteNetwork(tag: "rwn") == .regional)
        #expect(RouteNetwork(tag: "lwn") == .local)
        #expect(RouteNetwork(tag: nil) == .other)
        #expect(RouteNetwork(tag: "Local") == .other)
        #expect(RouteNetwork.leastImportantFirst == RouteNetwork.leastImportantFirst.sorted())
        #expect(RouteNetwork.leastImportantFirst.count == 5)
    }

    @Test("only the overview leaves routes out, and keeps the international and national ones")
    func overviewKeepsLongRoutes() {
        #expect(RouteSquareLevel.overview.minimumNetwork == .national)
        for level in [RouteSquareLevel.region, .area, .detail] {
            #expect(level.minimumNetwork == .other)
        }
    }
}
