//
//  ElevationSquareGridTests.swift
//  OpenHikesTests
//
//  Which square a height is in, where in it, and how a height between four
//  posts is read — a storage contract, like every set's names: the archive on
//  the tile server was built by the same arithmetic, and a post read one row
//  off is a height a few metres from where the hiker is, which nothing on
//  screen would show.
//

import Foundation
@testable import OpenHikes
import RealModule
import Testing

@Suite("Elevation square grid")
struct ElevationSquareGridTests {
    // MARK: - Names

    @Test("a square's name is its generation, row and column, and reads back")
    func names() {
        let square = ElevationSquare(row: 339, column: 1543)
        #expect(ElevationSquareGrid.recordName(for: square) == "elevation1_339_1543")
        #expect(ElevationSquareGrid.square(named: "elevation1_339_1543") == square)
    }

    @Test("a name that is no square of this generation reads as none", arguments: [
        "elevation2_339_1543",
        "elevation1_1440_0",
        "elevation1_0_2880",
        "elevation1_-1_0",
        "elevation1_339",
        "places1_137_192",
    ])
    func notASquare(_ name: String) {
        #expect(ElevationSquareGrid.square(named: name) == nil)
    }

    // MARK: - Copernicus' bands

    /// Copernicus' product handbook's table, held tile by tile: a band is
    /// named by its edge nearer the equator, in both hemispheres. Every edge
    /// here was read off a real tile before the world was built.
    @Test("a band's posts to a degree of longitude are Copernicus'", arguments: [
        (49, 3600), (50, 2400), (59, 2400), (60, 1800), (69, 1800), (70, 1200),
        (79, 1200), (80, 720), (84, 720), (85, 360), (89, 360),
        (-50, 3600), (-51, 2400), (-61, 1800), (-71, 1200), (-81, 720), (-86, 360), (-90, 360),
    ])
    func bands(tileSouth: Int, posts: Int) {
        #expect(ElevationSquareGrid.postsPerDegreeOfLongitude(tileSouth: tileSouth) == posts)
    }

    @Test("every band's columns divide into eight squares a degree")
    func columnsDivide() {
        for row in 0..<ElevationSquareGrid.rowCount {
            let perDegree = ElevationSquareGrid.postsPerDegreeOfLongitude(
                tileSouth: ElevationSquareGrid.tileSouth(ofSquareRow: row)
            )
            #expect(ElevationSquareGrid.columnsPerSquare(row: row) * ElevationSquareGrid.squaresPerDegree == perDegree)
        }
    }

    // MARK: - Where a post is

    @Test("a post's square and index, row by row from the square's north-west post")
    func placeOfAPost() {
        let place = ElevationSquareGrid.place(of: ElevationPost(row: 152_101, column: 693_002))
        #expect(place.square == ElevationSquare(row: 338, column: 1540))
        #expect(place.index == 1 * 450 + 2)

        // North of 50°, a square is 300 columns wide.
        let north = ElevationSquareGrid.place(of: ElevationPost(row: 135_001, column: 601))
        #expect(north.square == ElevationSquare(row: 300, column: 2))
        #expect(north.index == 1 * 300 + 1)
    }

    @Test("a point on a post reads that post alone")
    func onAPost() throws {
        let around = try #require(ElevationSquareGrid.posts(aroundLatitude: 47.5, longitude: 12.5))
        #expect(around.northWest == ElevationPost(row: 153_000, column: 693_000))
        #expect(around.northEastward == 0)
        #expect(around.southward == 0)
        let height = around.height { Double($0.row * 10 + $0.column) }
        #expect(height == Double(153_000 * 10 + 693_000))
    }

    /// The plane through four posts, read anywhere between them, is the
    /// plane: a height that is a sum of a row's and a column's reads back
    /// exactly.
    @Test("a height between posts is the plane through the four around it")
    func betweenPosts() throws {
        let rowStep = 1.0 / 3600
        let latitude = 47.5 - 0.25 * rowStep
        let longitude = 12.5 + 0.75 * rowStep
        let around = try #require(ElevationSquareGrid.posts(aroundLatitude: latitude, longitude: longitude))
        #expect(around.southWest == ElevationPost(row: 153_001, column: 693_000))
        #expect(around.northEast == ElevationPost(row: 153_000, column: 693_001))

        let height = try #require(around.height { post in
            1000 + Double(post.row - 153_000) * 4 + Double(post.column - 693_000) * 8
        })
        #expect(height.isApproximatelyEqual(to: 1000 + 0.25 * 4 + 0.75 * 8, absoluteTolerance: 1e-6))
    }

    /// Across 50°N the rows are spaced differently: the row north of the
    /// parallel is in the 1½" band, the row on it in the 1" one. Each is read
    /// at its own spacing.
    @Test("either side of a band's edge, each row is read at its own spacing")
    func acrossABandEdge() throws {
        let around = try #require(ElevationSquareGrid.posts(aroundLatitude: 50.0001, longitude: 0.5))
        #expect(around.northWest.row == 143_999)
        #expect(around.southWest.row == 144_000)
        #expect(around.northWest.column == 180 * 2400 + 1200)
        #expect(around.southWest.column == 180 * 3600 + 1800)
    }

    @Test("the last column's neighbor to the east is the first, across the antimeridian")
    func acrossTheAntimeridian() throws {
        let around = try #require(ElevationSquareGrid.posts(aroundLatitude: 10, longitude: 179.99999))
        #expect(around.northWest.column == 360 * 3600 - 1)
        #expect(around.northEast.column == 0)
        let west = try #require(ElevationSquareGrid.posts(aroundLatitude: 10, longitude: -180))
        let east = try #require(ElevationSquareGrid.posts(aroundLatitude: 10, longitude: 180))
        #expect(west.northWest.column == 0)
        #expect(east.northWest.column == 0, "180° east is 180° west")
    }

    @Test("the poles are read from the last rows there are")
    func atThePoles() throws {
        let north = try #require(ElevationSquareGrid.posts(aroundLatitude: 90, longitude: 0))
        #expect(north.northWest.row == 0)
        let south = try #require(ElevationSquareGrid.posts(aroundLatitude: -90, longitude: 0))
        #expect(south.southWest.row == ElevationSquareGrid.postRowCount - 1)
        #expect(ElevationSquareGrid.place(of: south.southWest).square.row == ElevationSquareGrid.rowCount - 1)
    }

    @Test("a coordinate that is no place on the Earth has no posts", arguments: [
        (Double.nan, 0.0), (0, .nan), (90.5, 0), (-91, 0), (0, .infinity),
    ])
    func noPlace(latitude: Double, longitude: Double) {
        #expect(ElevationSquareGrid.posts(aroundLatitude: latitude, longitude: longitude) == nil)
    }

    @Test("a height with any of its four posts unknown is no height")
    func unknownPost() throws {
        let around = try #require(ElevationSquareGrid.posts(aroundLatitude: 47.5001, longitude: 12.5001))
        let southEast = around.southEast
        #expect(around.height { $0 == southEast ? nil : 500 } == nil)
    }
}
