//
//  PlaceSquareGrid.swift
//  OpenHikes
//
//  The squares OpenStreetMap's places — the summits, springs, huts and
//  viewpoints a place search offers — are filed in ahead of time, what each
//  one's record is called, and which of them a search has to read.
//
//  Every place search was a question put to Overpass: the maker's *Search
//  this area*, *Places Around Trail*, and *Add Place* and *Places Nearby*
//  while recording, the last two usually asked on a hillside with one bar of
//  signal. The wait was the public server's queue rather than the query, as it
//  was for the day hikes (see ``TrailCellGrid``), so the answer is built ahead
//  of time the same way: `Scripts/trail-cells.sh build-places` reads a planet
//  file and files every place ``TrailPointQuery`` asks for under one square of
//  this grid, kept on the tile server one tile a square (see
//  ``SquareArchive``), where a search fetches the few squares it needs by
//  name; builds before that read them as records of the public database. See ``PlaceSquareLibrary`` for
//  the reading and ``PlaceSquareFile`` for what one square holds.
//
//  ## A whole degree, and a place filed under every square it reaches
//
//  Measured on planet-261109: 3,512,623 places, 57.6 MB in 14,795 squares a
//  degree each way, the median square 599 bytes, one in a hundred over 61 KB,
//  and the largest, around Zürich, 229 KB for 16,478 places. The square around
//  Berchtesgaden is 146 KB for 7,265.
//
//  Quarter-degree squares, the day hikes' size, were measured too: 109,341 of
//  them, the median 185 bytes and the largest 72 KB. A square that small saves
//  a search a few kilobytes and costs everything else — seven times the
//  records to upload, at about ten a second, and seven times the fetches as a
//  hiker moves. At a degree, the widest place search — 20 km across, see
//  ``TrailPointQuery/maximumRadiusMeters`` — reads one to four squares, and
//  each one kept is 111 by 76 km of places at 47°N on the device, for *Add
//  Place* to offer where there is no signal. See
//  ``PlaceSquareLibrary/keptPlaces(near:limit:)``.
//
//  A node is filed under the square it stands in, and a way or a relation — a
//  hut, a campsite — under every square the box around it touches. So a search
//  reads the squares its own boxes touch and no more, and finds every place
//  that reaches into them, as Overpass finds a way by any of its nodes:
//  ``TrailCellGrid`` files a route once and reads ten kilometres further for
//  the ones that reach out of their squares, and a reach here would have to be
//  as wide as the widest campsite. Few reach over an edge: on planet-261109,
//  413 places, the widest of them half a degree across, and none across the
//  date line.
//
//  ## Compiled twice
//
//  By the app, which reads the squares, and by `Scripts/trail-cells.sh` into
//  the tool that writes them, for the reason ``TrailCellGrid`` gives: this
//  file imports Foundation and nothing of the app's, and says `nonisolated` on
//  every declaration. Its boxes are ``TrailCellBounds``, which the tool
//  compiles too.
//

import Foundation

/// One square of the places' grid.
nonisolated struct PlaceSquare: Hashable, Sendable {
    /// Counted north from the south pole, so that no record name carries a
    /// sign.
    var row: Int
    /// Counted east from the antimeridian.
    var column: Int
}

/// Where the places' squares are, and what they are called.
nonisolated enum PlaceSquareGrid {
    /// The generation of ``PlaceSquareFile`` these records hold, and part of
    /// every record's name, for the reason ``TrailCellGrid/generation`` is.
    static let generation = 1

    /// How many squares a degree is cut into, each way.
    static let squaresPerDegree = 1

    private static let halfTurnDegrees: Double = 180
    private static let fullTurnDegrees: Double = 360
    private static let quarterTurnDegrees: Double = 90

    static var rowCount: Int { Int(halfTurnDegrees) * squaresPerDegree }
    static var columnCount: Int { Int(fullTurnDegrees) * squaresPerDegree }
}

// MARK: - Which squares

nonisolated extension PlaceSquareGrid {
    /// Every square `box` touches, each once: the ones a search reads, and
    /// the ones a place is filed under.
    ///
    /// `box` is one a search has already split at the antimeridian — see
    /// ``CuratedTrailQuery/searchBoxes(for:)`` — or a place's, which is never
    /// split (see ``PlaceSquareFile/Box``), so its `east` is never west of its
    /// `west`. Any longitude is taken, however many times it has wrapped, and
    /// the north pole itself belongs to the last row rather than to one past
    /// it. Empty for a box that is not one.
    static func squares(covering box: TrailCellBounds) -> [PlaceSquare] {
        guard box.south.isFinite, box.west.isFinite, box.north.isFinite, box.east.isFinite,
              box.south <= box.north, box.west <= box.east
        else { return [] }
        let rows = row(ofLatitude: box.south)...row(ofLatitude: box.north)
        let first = unwrappedColumn(ofLongitude: box.west)
        let last = unwrappedColumn(ofLongitude: box.east)
        // All the way round, or further: every column, and each only once.
        let columns = last - first < columnCount ? (first...last).map(wrapped) : Array(0..<columnCount)
        return rows.flatMap { row in
            columns.map { PlaceSquare(row: row, column: $0) }
        }
    }

    private static func row(ofLatitude latitude: Double) -> Int {
        let index = Int(((latitude + quarterTurnDegrees) * Double(squaresPerDegree)).rounded(.down))
        return min(rowCount - 1, max(0, index))
    }

    /// The column a longitude falls in, counted on without wrapping, so a
    /// span across the antimeridian is still a run of consecutive numbers.
    private static func unwrappedColumn(ofLongitude longitude: Double) -> Int {
        Int(((longitude + halfTurnDegrees) * Double(squaresPerDegree)).rounded(.down))
    }

    private static func wrapped(_ column: Int) -> Int {
        let remainder = column % columnCount
        return remainder < 0 ? remainder + columnCount : remainder
    }
}

// MARK: - What a square's record is called

nonisolated extension PlaceSquareGrid {
    private static var namePrefix: String { "places\(generation)" }
    private static let nameSeparator: Character = "_"
    private static let namePartCount = 3

    /// The name of the record that says what this generation's squares cover,
    /// as ``TrailCellGrid/manifestRecordName`` does for the day hikes'.
    static var manifestRecordName: String { "\(namePrefix)\(nameSeparator)manifest" }

    /// The name `square`'s record is saved under and fetched by.
    ///
    /// A storage contract, like every record name this app derives: the tool
    /// writes a square under it and every installed build asks for it.
    static func recordName(for square: PlaceSquare) -> String {
        "\(namePrefix)\(nameSeparator)\(square.row)\(nameSeparator)\(square.column)"
    }

    /// The square a record name is for, or `nil` for a name that is not one
    /// of this generation's squares.
    static func square(named name: String) -> PlaceSquare? {
        let parts = name.split(separator: nameSeparator, omittingEmptySubsequences: false)
        guard parts.count == namePartCount, parts[0] == namePrefix,
              let row = Int(parts[1]), let column = Int(parts[2]),
              (0..<rowCount).contains(row), (0..<columnCount).contains(column)
        else { return nil }
        return PlaceSquare(row: row, column: column)
    }
}
