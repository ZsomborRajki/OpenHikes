//
//  ElevationSquareGrid.swift
//  OpenHikes
//
//  The heights the app gives a line that has none — a trail drawn in the
//  maker, a route from OpenStreetMap, a GPX file exported without `<ele>` —
//  filed by square, as the tile server holds them: which square a height is
//  in, where in it, and how a height between four of them is read.
//
//  ## Copernicus' grid, as it is
//
//  The heights are the Copernicus DEM's at 30 m (GLO-30), which the European
//  Union gives away for any use, with the credit ``ElevationCredit`` spells.
//  Its tiles are a degree square, each a grid of *posts*: a height measured at
//  a point, the first one exactly on the tile's north-west corner
//  (`PixelIsPoint`), one every arc-second southward and, in longitude, as many
//  to a degree as its band of latitude keeps — 3,600 to 50°, then fewer
//  poleward, so that a post is about 30 m from the next everywhere
//  (``postsPerDegreeOfLongitude(tileSouth:)``). Nothing is resampled: a
//  square holds Copernicus' own posts, so a height read here is one of theirs
//  or the plane between four of them, never a resampling of a resampling.
//
//  ## A square is an eighth of a degree
//
//  450 rows of posts, and an eighth of its band's columns: 450 at the equator,
//  45 beside the poles. Around 14 by 9 km at 47°N, so a twenty-kilometre
//  trail reads two to four of them and the whole of a valley's hikes a dozen.
//  Packed (``ElevationSquareFile``) one is about 100 KB in the Alps, 30 KB on
//  a plain and nothing at sea, which has no square at all. The world, built
//  on 2026-11-26, is 1,464,930 squares and 66.4 GB, 45 KB a square: 229,470
//  more were sea level throughout and are not there.
//
//  Rows are counted from the North Pole and columns east from the
//  antimeridian, as Copernicus' rows and columns run, so a degree tile is the
//  8 × 8 squares at a multiple of eight. In the archive a square is the tile
//  at its column and row (``SquareArchive``), and those 64 are then one run
//  of tile ids, which is what lets the build write the archive in order.
//
//  ## Reading a height
//
//  Between the posts a height is the plane through the four around it: the
//  two posts either side on the row above, the two on the row below, each row
//  at its own spacing — which differ only across the 50°, 60°, 70°, 80° and
//  85° parallels, where the band changes — then the two rows together. The
//  four can be in up to four squares; ``posts(aroundLatitude:longitude:)``
//  names them, so a caller can fetch every square a line needs at once.
//
//  ## Compiled twice
//
//  By the app, and by `Scripts/trail-cells.sh` into the tool that builds the
//  archive, so the two cannot disagree about where a post is. This file
//  imports Foundation and nothing of the app's, and says `nonisolated` on
//  every declaration.
//

import Foundation

/// One square of the elevation grid: an eighth of a degree each way, rows
/// counted from the North Pole, columns eastward from the antimeridian.
nonisolated struct ElevationSquare: Hashable, Sendable {
    var row: Int
    var column: Int
}

/// One post of the grid: rows of posts from the North Pole, an arc-second
/// apart, and columns eastward from the antimeridian at the spacing of the
/// row's band.
nonisolated struct ElevationPost: Hashable, Sendable {
    var row: Int
    var column: Int
}

nonisolated enum ElevationSquareGrid {
    /// The generation of the files the squares hold, in every square's name
    /// and in the archive's entry in the tile server's manifest. A file an
    /// installed build would read wrong goes up as the next one, beside it.
    static let generation = 1

    static let squaresPerDegree = 8

    /// Posts in a degree of latitude: one an arc-second, in every band.
    static let postsPerDegreeOfLatitude = 3600

    static var rowsPerSquare: Int { postsPerDegreeOfLatitude / squaresPerDegree }

    static var rowCount: Int { Int(halfTurnDegrees) * squaresPerDegree }
    static var columnCount: Int { Int(fullTurnDegrees) * squaresPerDegree }

    /// Rows of posts from pole to pole. The South Pole's own row is no tile's:
    /// the southernmost tiles stop an arc-second short of it.
    static var postRowCount: Int { Int(halfTurnDegrees) * postsPerDegreeOfLatitude }

    /// Posts in a degree of longitude, in the band of the Copernicus tile
    /// whose southern edge is at `tileSouth` degrees: one an arc-second to
    /// 50°, then one every 1½, 2, 3, 5 and 10 arc-seconds — Copernicus'
    /// product handbook's table. A band is named by its edge nearer the
    /// equator, so the tiles from 50° to 51° north and from 50° to 51° south
    /// are both in the 1½" band. The build holds every tile to this.
    static func postsPerDegreeOfLongitude(tileSouth: Int) -> Int {
        let equatorward = tileSouth >= 0 ? tileSouth : -(tileSouth + 1)
        return Band.all.last { $0.from <= equatorward }?.posts ?? postsPerDegreeOfLatitude
    }

    /// The table, a band to a line: the latitude it starts at, poleward
    /// from the equator, and its posts to a degree of longitude.
    private enum Band {
        static let fromFifty = 50
        static let fromSixty = 60
        static let fromSeventy = 70
        static let fromEighty = 80
        static let fromEightyFive = 85
        static let postsFromFifty = 2400
        static let postsFromSixty = 1800
        static let postsFromSeventy = 1200
        static let postsFromEighty = 720
        static let postsFromEightyFive = 360

        static let all: [(from: Int, posts: Int)] = [
            (0, postsPerDegreeOfLatitude),
            (fromFifty, postsFromFifty),
            (fromSixty, postsFromSixty),
            (fromSeventy, postsFromSeventy),
            (fromEighty, postsFromEighty),
            (fromEightyFive, postsFromEightyFive),
        ]
    }

    /// The southern edge of the tile a row of squares is in.
    static func tileSouth(ofSquareRow row: Int) -> Int {
        Int(quarterTurnDegrees) - 1 - row / squaresPerDegree
    }

    /// The southern edge of the tile a row of posts is in.
    static func tileSouth(ofPostRow row: Int) -> Int {
        Int(quarterTurnDegrees) - 1 - row / postsPerDegreeOfLatitude
    }

    /// How many columns of posts a square in `row` holds.
    static func columnsPerSquare(row: Int) -> Int {
        postsPerDegreeOfLongitude(tileSouth: tileSouth(ofSquareRow: row)) / squaresPerDegree
    }

    /// The square a post is in, and the post's index in it, row by row from
    /// its north-west post.
    static func place(of post: ElevationPost) -> (square: ElevationSquare, index: Int) {
        let row = post.row / rowsPerSquare
        let columns = columnsPerSquare(row: row)
        return (
            ElevationSquare(row: row, column: post.column / columns),
            (post.row % rowsPerSquare) * columns + post.column % columns
        )
    }

    private static let quarterTurnDegrees: Double = 90
    private static let halfTurnDegrees: Double = 180
    private static let fullTurnDegrees: Double = 360
}

// MARK: - Reading a height

nonisolated extension ElevationSquareGrid {
    /// The posts a height at a point is read from: the two either side of it
    /// on the row of posts at or north of it, and the two on the next row
    /// south, with how far it is along each — see the file header.
    struct Neighborhood: Equatable, Sendable {
        var northWest: ElevationPost
        var northEast: ElevationPost
        var southWest: ElevationPost
        var southEast: ElevationPost
        /// How far east of the western post on the northern row, 0 to 1.
        var northEastward: Double
        /// The same on the southern row, which can be spaced otherwise.
        var southEastward: Double
        /// How far south of the northern row, 0 to 1.
        var southward: Double

        var posts: [ElevationPost] { [northWest, northEast, southWest, southEast] }

        /// The height, given each post's: `nil` when any of the four has
        /// none.
        func height(_ post: (ElevationPost) -> Double?) -> Double? {
            guard let northWestHeight = post(northWest), let northEastHeight = post(northEast),
                  let southWestHeight = post(southWest), let southEastHeight = post(southEast)
            else { return nil }
            let north = northWestHeight + (northEastHeight - northWestHeight) * northEastward
            let south = southWestHeight + (southEastHeight - southWestHeight) * southEastward
            return north + (south - north) * southward
        }
    }

    /// The four posts around a point, or `nil` for a coordinate that is no
    /// place on the Earth.
    static func posts(aroundLatitude latitude: Double, longitude: Double) -> Neighborhood? {
        guard latitude.isFinite, longitude.isFinite, abs(latitude) <= quarterTurnDegrees else { return nil }
        let position = (quarterTurnDegrees - latitude) * Double(postsPerDegreeOfLatitude)
        let lastRow = postRowCount - 1
        let north = min(Int(position.rounded(.down)), lastRow)
        let south = min(north + 1, lastRow)
        let northColumns = columns(ofPostRow: north, atLongitude: longitude)
        let southColumns = columns(ofPostRow: south, atLongitude: longitude)
        return Neighborhood(
            northWest: ElevationPost(row: north, column: northColumns.west),
            northEast: ElevationPost(row: north, column: northColumns.east),
            southWest: ElevationPost(row: south, column: southColumns.west),
            southEast: ElevationPost(row: south, column: southColumns.east),
            northEastward: northColumns.eastward,
            southEastward: southColumns.eastward,
            southward: min(max(position - Double(north), 0), 1)
        )
    }

    /// The two columns of posts either side of `longitude` on a row, at that
    /// row's spacing, and how far east of the first it is. The last column's
    /// neighbor to the east is the first, across the antimeridian.
    private static func columns(
        ofPostRow row: Int,
        atLongitude longitude: Double
    ) -> (west: Int, east: Int, eastward: Double) {
        let perDegree = postsPerDegreeOfLongitude(tileSouth: tileSouth(ofPostRow: row))
        let count = Int(fullTurnDegrees) * perDegree
        var position = ((longitude + halfTurnDegrees) * Double(perDegree))
            .truncatingRemainder(dividingBy: Double(count))
        if position < 0 { position += Double(count) }
        let west = min(Int(position.rounded(.down)), count - 1)
        return (west, (west + 1) % count, min(max(position - Double(west), 0), 1))
    }
}

// MARK: - Names

nonisolated extension ElevationSquareGrid {
    private static var namePrefix: String { "elevation\(generation)" }
    private static let nameSeparator: Character = "_"
    private static let namePartCount = 3

    /// The square's name, by which it is asked for:
    /// `elevation1_<row>_<column>`.
    static func recordName(for square: ElevationSquare) -> String {
        "\(namePrefix)\(nameSeparator)\(square.row)\(nameSeparator)\(square.column)"
    }

    /// The square named `name`, or `nil` for a name that is not one of this
    /// generation's squares.
    static func square(named name: String) -> ElevationSquare? {
        let parts = name.split(separator: nameSeparator, omittingEmptySubsequences: false)
        guard parts.count == namePartCount, parts[0] == namePrefix,
              let row = Int(parts[1]), let column = Int(parts[2]),
              (0..<rowCount).contains(row), (0..<columnCount).contains(column)
        else { return nil }
        return ElevationSquare(row: row, column: column)
    }
}
