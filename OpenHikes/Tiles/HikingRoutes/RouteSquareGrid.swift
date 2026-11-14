//
//  RouteSquareGrid.swift
//  OpenHikes
//
//  The squares the hiking-routes layer is filed in: four levels of detail,
//  which zooms each one is drawn at, and what each square's record is called.
//
//  The layer is every `route=hiking` relation OpenStreetMap has, drawn by the
//  app over whichever map is selected. `Scripts/trail-cells.sh build-routes`
//  reads a planet file, keeps each way that belongs to a route **once** —
//  with the routes it belongs to, so a path four routes share is one line
//  rather than four — and files the ways into squares, one record a square in
//  the public database, which the map fetches by name for the ground it
//  draws. See ``RouteSquareFile`` for what a square holds.
//
//  ## Four levels, measured on the planet of 2026-11-09
//
//  273,074 routes, 4.6 million ways and 70 million points, 1.51 million km of
//  network once a shared way is counted once. Drawn at full detail from a
//  continent's view that is far too much to fetch, and drawn simplified at a
//  street's view it misses the path, so each level of detail is a set of
//  squares of its own, simplified to what its zooms can show:
//
//  | Level      | Zooms  | Square | Simplified | Units  | Routes          | Whole set | Largest |
//  |------------|--------|--------|------------|--------|-----------------|-----------|---------|
//  | `overview` | 7–9    | 4°     | 300 m      | 1e-4°  | iwn and nwn     | 8.6 MB    | 768 KB  |
//  | `region`   | 10–11  | 1°     | 40 m       | 1e-5°  | all             | 46 MB     | 623 KB  |
//  | `area`     | 12–13  | 0.5°   | 8 m        | 1e-5°  | all             | 76 MB     | 364 KB  |
//  | `detail`   | 14 on  | 0.25°  | none       | 1e-6°  | all             | 222 MB    | 404 KB  |
//
//  A square's side is chosen so that the busiest — the Alps, the Ardennes,
//  the Black Forest — stays under a few hundred kilobytes, which one map view
//  fetches one to four of. 4° squares at zooms 10 and 11 were 6 MB there.
//
//  ## A segment is filed in every square its box touches
//
//  A way is cut into one line a square, and a segment belongs to every square
//  its two ends span — usually one, two along an edge, four at a corner — so
//  a map tile needs only the squares it overlaps to draw every line through
//  it, with nothing missing where a long simplified segment cuts across a
//  corner.
//
//  ## Compiled twice
//
//  By the app and by the tool that writes the squares, for the reason
//  ``TrailCellGrid`` is: the two cannot disagree about which square a line is
//  in or what its record is called. So this file imports Foundation and
//  nothing else, and says `nonisolated` on every declaration.
//

import Foundation

/// The kind of network a route is waymarked as — OpenStreetMap's `network`
/// tag on a hiking route — ordered from least to most important.
///
/// What a line is coloured by, and the order lines are drawn in: where routes
/// share a way, the most important one's colour is the one shown.
nonisolated enum RouteNetwork: UInt8, Comparable, Sendable {
    case international = 4
    case local = 1
    case national = 3
    /// No `network` tag, or one OpenStreetMap's hiking scheme does not have.
    case other = 0
    case regional = 2

    /// Every network, least important first: the order lines are stroked in.
    static let leastImportantFirst: [Self] = [.other, .local, .regional, .national, .international]

    init(tag: String?) {
        switch tag {
        case "iwn": self = .international
        case "nwn": self = .national
        case "rwn": self = .regional
        case "lwn": self = .local
        default: self = .other
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// One of the four sets of squares. See this file's header for the table.
nonisolated enum RouteSquareLevel: Int, Sendable {
    case area = 2
    case detail = 3
    case overview = 0
    case region = 1

    /// Every level, shallowest zooms first.
    static let shallowestFirst: [Self] = [.overview, .region, .area, .detail]

    /// The shallowest zoom the layer draws at all. Shallower, a marked route
    /// is a thread across a country nobody could follow from it.
    static let minimumZoom = 7

    /// The level drawn at map zoom `zoom`, or `nil` for one shallower than
    /// ``minimumZoom``.
    static func level(forZoom zoom: Int) -> Self? {
        guard zoom >= minimumZoom else { return nil }
        return shallowestFirst.last { $0.firstZoom <= zoom }
    }

    /// The shallowest zoom this level is drawn at.
    var firstZoom: Int {
        switch self {
        case .overview: Self.minimumZoom
        case .region: Self.regionZoom
        case .area: Self.areaZoom
        case .detail: Self.detailZoom
        }
    }

    /// A square's side, in degrees, both ways.
    var squareDegrees: Double {
        switch self {
        case .overview: Self.overviewSquareDegrees
        case .region: 1
        case .area: 0.5
        case .detail: 0.25
        }
    }

    /// How far a simplified line may stray from the way, in meters: under a
    /// pixel at the level's deepest zoom. `0` keeps every point.
    var toleranceMeters: Double {
        switch self {
        case .overview: Self.overviewToleranceMeters
        case .region: Self.regionToleranceMeters
        case .area: Self.areaToleranceMeters
        case .detail: 0
        }
    }

    /// How many coordinate units make a degree in this level's files.
    var coordinateScale: Int32 {
        switch self {
        case .overview: Self.overviewScale
        case .region, .area: Self.areaScale
        case .detail: Self.detailScale
        }
    }

    /// The least important network filed at this level. From a continent's
    /// view only the long routes read as routes; the rest is a texture.
    var minimumNetwork: RouteNetwork {
        self == .overview ? .national : .other
    }

    /// What this level's record names say it is.
    var nameToken: String { "z\(firstZoom)" }

    private static let regionZoom = 10
    private static let areaZoom = 12
    private static let detailZoom = 14
    private static let overviewSquareDegrees: Double = 4
    private static let overviewToleranceMeters: Double = 300
    private static let regionToleranceMeters: Double = 40
    private static let areaToleranceMeters: Double = 8
    private static let overviewScale: Int32 = 10_000
    private static let areaScale: Int32 = 100_000
    private static let detailScale: Int32 = 1_000_000
}

/// One square of one level.
nonisolated struct RouteSquare: Hashable, Sendable {
    var level: RouteSquareLevel
    /// Counted north from the south pole, so no record name carries a sign.
    var row: Int
    /// Counted east from the antimeridian.
    var column: Int
}

/// A south/west/north/east box in degrees.
nonisolated struct RouteSquareBounds: Equatable, Sendable {
    var south: Double
    var west: Double
    var north: Double
    var east: Double
}

nonisolated enum RouteSquareGrid {
    /// The generation of ``RouteSquareFile`` these records hold, and part of
    /// every record's name, for the reason ``TrailCellGrid/generation`` is.
    static let generation = 1

    private static let halfTurnDegrees: Double = 180
    private static let fullTurnDegrees: Double = 360
    private static let quarterTurnDegrees: Double = 90

    static func rowCount(of level: RouteSquareLevel) -> Int {
        Int((halfTurnDegrees / level.squareDegrees).rounded())
    }

    static func columnCount(of level: RouteSquareLevel) -> Int {
        Int((fullTurnDegrees / level.squareDegrees).rounded())
    }
}

// MARK: - Which square

nonisolated extension RouteSquareGrid {
    /// The square of `level` that holds a point. Any longitude is taken,
    /// however many times it has wrapped, and the north pole belongs to the
    /// last row.
    static func square(at level: RouteSquareLevel, latitude: Double, longitude: Double) -> RouteSquare {
        RouteSquare(level: level, row: row(of: latitude, at: level), column: column(of: longitude, at: level))
    }

    /// Every square of `level` that overlaps `box`, which does not cross the
    /// antimeridian. Empty for a box that is not one.
    static func squares(at level: RouteSquareLevel, covering box: RouteSquareBounds) -> [RouteSquare] {
        guard box.south.isFinite, box.west.isFinite, box.north.isFinite, box.east.isFinite,
              box.south <= box.north, box.west <= box.east
        else { return [] }
        let rows = row(of: box.south, at: level)...row(of: box.north, at: level)
        let first = unwrappedColumn(of: box.west, at: level)
        let last = unwrappedColumn(of: box.east, at: level)
        let columns = last - first < columnCount(of: level)
            ? (first...last).map { wrapped($0, at: level) }
            : Array(0..<columnCount(of: level))
        return rows.flatMap { row in
            columns.map { RouteSquare(level: level, row: row, column: $0) }
        }
    }

    /// The ground a square covers.
    static func bounds(of square: RouteSquare) -> RouteSquareBounds {
        let side = square.level.squareDegrees
        let south = Double(square.row) * side - quarterTurnDegrees
        let west = Double(square.column) * side - halfTurnDegrees
        return RouteSquareBounds(south: south, west: west, north: south + side, east: west + side)
    }

    private static func row(of latitude: Double, at level: RouteSquareLevel) -> Int {
        let index = Int(((latitude + quarterTurnDegrees) / level.squareDegrees).rounded(.down))
        return min(rowCount(of: level) - 1, max(0, index))
    }

    private static func column(of longitude: Double, at level: RouteSquareLevel) -> Int {
        wrapped(unwrappedColumn(of: longitude, at: level), at: level)
    }

    private static func unwrappedColumn(of longitude: Double, at level: RouteSquareLevel) -> Int {
        Int(((longitude + halfTurnDegrees) / level.squareDegrees).rounded(.down))
    }

    private static func wrapped(_ column: Int, at level: RouteSquareLevel) -> Int {
        let count = columnCount(of: level)
        let remainder = column % count
        return remainder < 0 ? remainder + count : remainder
    }
}

// MARK: - What a square's record is called

nonisolated extension RouteSquareGrid {
    private static var namePrefix: String { "routes\(generation)" }
    private static let nameSeparator: Character = "_"
    private static let namePartCount = 4

    /// The name of the record that says what this generation's squares cover,
    /// as ``TrailCellGrid/manifestRecordName`` does for the day hikes'.
    static var manifestRecordName: String { "\(namePrefix)\(nameSeparator)manifest" }

    /// The name `square`'s record is saved under and fetched by — a storage
    /// contract, like every record name this app derives.
    static func recordName(for square: RouteSquare) -> String {
        [namePrefix, square.level.nameToken, String(square.row), String(square.column)]
            .joined(separator: String(nameSeparator))
    }

    /// The square a record name is for, or `nil` for a name that is not one of
    /// this generation's squares.
    static func square(named name: String) -> RouteSquare? {
        let parts = name.split(separator: nameSeparator, omittingEmptySubsequences: false)
        guard parts.count == namePartCount, parts[0] == namePrefix,
              let level = RouteSquareLevel.shallowestFirst.first(where: { $0.nameToken == parts[1] }),
              let row = Int(parts[2]), let column = Int(parts[3]),
              (0..<rowCount(of: level)).contains(row), (0..<columnCount(of: level)).contains(column)
        else { return nil }
        return RouteSquare(level: level, row: row, column: column)
    }
}
