//
//  TrailCellGrid.swift
//  OpenHikes
//
//  The squares OpenStreetMap's hiking routes are filed in ahead of time, what
//  each one's record is called, and which of them a search has to read.
//
//  A curated search used to be a question put to Overpass, and the wait for
//  the answer was the public server's queue rather than the query: measured on
//  2026-11-13, `overpass-api.de` held the map above the sheet for 29 and 42
//  seconds and refused it outright twice more. So the answer is now built
//  ahead of time — `Scripts/trail-cells.sh` reads an OpenStreetMap extract and
//  files every waymarked day hike under one square of this grid — and kept in
//  the public database, one record a square, where a search fetches the few
//  squares it needs by name. See ``TrailCellLibrary`` for the reading and
//  ``TrailCellFile`` for what one square holds.
//
//  ## A quarter of a degree, and a route filed once
//
//  The whole world's day hikes were 159,165 routes that day, by Postpass's
//  count, in 11,242 squares this size that hold any at all: four routes in
//  the median square and 1,634 in the busiest. A square is about 28 km tall
//  and, at 47°N, 19 km wide — larger than the map most searches cover and
//  small enough that a busy one is a download a phone can make on a mountain.
//  Hungary's 3,308 routes are 166 squares and 2.0 MB between them, the median
//  5 KB and the largest 168 KB.
//
//  A route is filed under the square that holds the **center of its bounding
//  box**, and nowhere else. Filing it under every square its box touches was
//  measured against this over Hungary, on an earlier form of the file: half
//  as many bytes again to keep, and a search of the Pilis hills downloaded
//  499 KB from four squares where filing once downloaded 351 KB from six.
//  What filing once costs is that a route can reach out of its square — which
//  is what ``reachMeters`` is for. No route that is filed is wider than
//  ``maximumRouteSpanMeters`` corner to corner, so none reaches further than
//  half of that from the point it is filed under, and a search reads every
//  square within that distance of the map it is about. ``cells(reaching:)``
//  is that rule.
//
//  ## Compiled twice
//
//  By the app, which reads the squares, and by `Scripts/trail-cells.sh` into
//  the tool that writes them — the same source, so the two cannot disagree
//  about which square a route is in or what its record is called. That is why
//  this file imports Foundation and nothing else, says `nonisolated` on every
//  declaration, and carries a great-circle distance of its own beside the one
//  in `RouteGeometry`: the tool links none of the app's packages.
//  `TrailCellGridTests` holds the two distances to one answer.
//

import Foundation

/// One square of the grid: a quarter of a degree each way.
nonisolated struct TrailCell: Hashable, Sendable {
    /// Counted north from the south pole, so that no record name carries a
    /// sign.
    var row: Int
    /// Counted east from the antimeridian.
    var column: Int
}

/// A south/west/north/east box in degrees, as the grid measures one.
///
/// The grid's own type rather than ``CuratedTrailQuery/BoundingBox``, which
/// the tool cannot compile — see this file's header.
nonisolated struct TrailCellBounds: Equatable, Sendable {
    var south: Double
    var west: Double
    var north: Double
    var east: Double
}

/// Where the squares are, and what they are called.
nonisolated enum TrailCellGrid {
    /// The generation of ``TrailCellFile`` these records hold, and part of
    /// every record's name.
    ///
    /// In the name rather than in a field, because a build already installed
    /// keeps asking for the names it knows. A file it could not read has to
    /// go under a new name, beside the old ones, for as long as that build is
    /// in anybody's pocket.
    static let generation = 1

    /// How many squares a degree is cut into, each way.
    static let cellsPerDegree = 4

    /// The widest a route's bounding box may be, corner to corner in meters,
    /// and still be filed.
    ///
    /// The day-hike rule, and where its number is spelled:
    /// ``CuratedTrailQuery/maximumSpanMeters`` is this value rather than one
    /// of its own, and that file has the measurement behind it. It is spelled
    /// here because ``reachMeters`` rests on it — a route wider than this
    /// could stand further from its square than a search looks.
    static let maximumRouteSpanMeters: Double = 20_000

    /// The most members a relation may have and still be filed. See
    /// ``CuratedTrailQuery/maximumMemberCount``, which is this value.
    static let maximumMemberCount = 500

    /// How far outside the map it is about a search reads squares, in meters.
    ///
    /// Half of ``maximumRouteSpanMeters`` — the furthest a filed route's
    /// center can stand from any point on it — and a twentieth more, which
    /// covers the difference between the flat arithmetic ``cells(reaching:)``
    /// does and the ground.
    static let reachMeters: Double = maximumRouteSpanMeters / 2 * reachSlack

    private static let reachSlack = 1.05

    /// Ground meters in a degree, for turning ``reachMeters`` into degrees.
    ///
    /// Below the real figure at every latitude — a degree is between 110,570
    /// and 111,690 meters of latitude, and 111,320 of longitude at the
    /// equator — because the direction a mistake here may take is a square
    /// read that was not needed, never one left out.
    private static let metersPerDegree: Double = 110_000

    /// The smallest cosine a longitude reach is divided by.
    ///
    /// Near a pole a fixed distance is any number of degrees of longitude.
    /// This keeps the arithmetic finite there; ``TrailCellLibrary`` declines
    /// a search that would read that many squares.
    private static let minimumCosine = 0.01

    private static let halfTurnDegrees: Double = 180
    private static let fullTurnDegrees: Double = 360
    private static let quarterTurnDegrees: Double = 90

    static var rowCount: Int { Int(halfTurnDegrees) * cellsPerDegree }
    static var columnCount: Int { Int(fullTurnDegrees) * cellsPerDegree }
}

// MARK: - Which square

nonisolated extension TrailCellGrid {
    /// The square that holds a point.
    ///
    /// Any longitude is taken, however many times it has wrapped, and the
    /// north pole itself belongs to the last row rather than to one past it.
    static func cell(containingLatitude latitude: Double, longitude: Double) -> TrailCell {
        TrailCell(row: row(ofLatitude: latitude), column: column(ofLongitude: longitude))
    }

    /// The squares that can hold a route with a point inside `box`: every
    /// square within ``reachMeters`` of it.
    ///
    /// `box` is one a search has already split at the antimeridian — see
    /// ``CuratedTrailQuery/searchBoxes(for:)`` — so its `east` is never west
    /// of its `west`. The reach can still carry it across, and the columns
    /// wrap when it does. Empty for a box that is not one.
    static func cells(reaching box: TrailCellBounds) -> [TrailCell] {
        guard box.south.isFinite, box.west.isFinite, box.north.isFinite, box.east.isFinite,
              box.south <= box.north, box.west <= box.east
        else { return [] }
        let latitudeReach = reachMeters / metersPerDegree
        let south = max(-quarterTurnDegrees, box.south - latitudeReach)
        let north = min(quarterTurnDegrees, box.north + latitudeReach)
        // The poleward edge, where a degree of longitude is shortest and the
        // reach is therefore the most degrees.
        let poleward = max(abs(south), abs(north))
        let longitudeReach = reachMeters
            / (metersPerDegree * max(cos(poleward * .pi / halfTurnDegrees), minimumCosine))
        let rows = row(ofLatitude: south)...row(ofLatitude: north)
        let columns = columns(from: box.west - longitudeReach, through: box.east + longitudeReach)
        return rows.flatMap { row in
            columns.map { TrailCell(row: row, column: $0) }
        }
    }

    private static func row(ofLatitude latitude: Double) -> Int {
        let index = Int(((latitude + quarterTurnDegrees) * Double(cellsPerDegree)).rounded(.down))
        return min(rowCount - 1, max(0, index))
    }

    private static func column(ofLongitude longitude: Double) -> Int {
        wrapped(unwrappedColumn(ofLongitude: longitude))
    }

    /// The column a longitude falls in, counted on without wrapping, so a
    /// span across the antimeridian is still a run of consecutive numbers.
    private static func unwrappedColumn(ofLongitude longitude: Double) -> Int {
        Int(((longitude + halfTurnDegrees) * Double(cellsPerDegree)).rounded(.down))
    }

    private static func wrapped(_ column: Int) -> Int {
        let remainder = column % columnCount
        return remainder < 0 ? remainder + columnCount : remainder
    }

    /// Every column between two longitudes, each once, wrapped into the grid.
    private static func columns(from west: Double, through east: Double) -> [Int] {
        let first = unwrappedColumn(ofLongitude: west)
        let last = unwrappedColumn(ofLongitude: east)
        // All the way round, or further: every column, and each only once.
        guard last - first < columnCount else { return Array(0..<columnCount) }
        return (first...last).map(wrapped)
    }
}

// MARK: - What a square's record is called

nonisolated extension TrailCellGrid {
    private static var namePrefix: String { "trails\(generation)" }
    private static let nameSeparator: Character = "_"
    private static let namePartCount = 3

    /// The name of the record that says what this generation's squares cover.
    /// See ``TrailCellFetch/Manifest``.
    static var manifestRecordName: String { "\(namePrefix)\(nameSeparator)manifest" }

    /// The name `cell`'s record is saved under and fetched by.
    ///
    /// A storage contract, like every record name this app derives: the tool
    /// writes a square under it and every installed build asks for it. ASCII,
    /// far inside the 255 characters a record name may have, and it does not
    /// start with the underscore CloudKit keeps for itself.
    static func recordName(for cell: TrailCell) -> String {
        "\(namePrefix)\(nameSeparator)\(cell.row)\(nameSeparator)\(cell.column)"
    }

    /// The square a record name is for, or `nil` for a name that is not one
    /// of this generation's squares.
    static func cell(named name: String) -> TrailCell? {
        let parts = name.split(separator: nameSeparator, omittingEmptySubsequences: false)
        guard parts.count == namePartCount, parts[0] == namePrefix,
              let row = Int(parts[1]), let column = Int(parts[2]),
              (0..<rowCount).contains(row), (0..<columnCount).contains(column)
        else { return nil }
        return TrailCell(row: row, column: column)
    }
}

// MARK: - Measuring a route's box

nonisolated extension TrailCellBounds {
    /// How wide the box is in degrees of longitude, read the short way round.
    ///
    /// The rule ``CuratedTrailQuery/longitudeSpanDegrees(of:)`` argues: a
    /// route that steps across the date line has a box that reads as the
    /// whole world, and the short reading is the only one that can be a day
    /// hike.
    var longitudeSpanDegrees: Double {
        let raw = east - west
        return raw > Self.halfTurnDegrees ? raw - Self.fullTurnDegrees : raw
    }

    /// The box's diagonal on the ground, in meters — what
    /// ``TrailCellGrid/maximumRouteSpanMeters`` is a ceiling on.
    ///
    /// Great-circle along the west edge and along the south one, the way
    /// ``CuratedTrailQuery/spanMeters(of:)`` measures it, so the tool leaves
    /// out exactly the routes the app would.
    var spanMeters: Double {
        let height = Self.distanceMeters(
            fromLatitude: south,
            longitude: west,
            toLatitude: north,
            longitude: west
        )
        let width = Self.distanceMeters(
            fromLatitude: south,
            longitude: west,
            toLatitude: south,
            longitude: west + longitudeSpanDegrees
        )
        return (height * height + width * width).squareRoot()
    }

    /// The middle of the box, which is the point a route is filed under.
    ///
    /// Walked half a width east of `west`, like
    /// ``CuratedTrailQuery/center(of:)``, so a route across the date line is
    /// filed beside it rather than on the far side of the world.
    var center: (latitude: Double, longitude: Double) {
        (latitude: (south + north) / 2, longitude: west + longitudeSpanDegrees / 2)
    }

    private static let halfTurnDegrees: Double = 180
    private static let fullTurnDegrees: Double = 360
    /// The same radius `RouteGeometry` measures with.
    private static let earthRadiusMeters = 6_371_008.8

    /// `RouteGeometry.distanceMeters(from:to:)`, on plain numbers.
    private static func distanceMeters(
        fromLatitude startLatitude: Double,
        longitude startLongitude: Double,
        toLatitude endLatitude: Double,
        longitude endLongitude: Double
    ) -> Double {
        let radians = Double.pi / halfTurnDegrees
        var longitudeDelta = (endLongitude - startLongitude)
            .truncatingRemainder(dividingBy: fullTurnDegrees)
        if longitudeDelta > halfTurnDegrees { longitudeDelta -= fullTurnDegrees }
        if longitudeDelta < -halfTurnDegrees { longitudeDelta += fullTurnDegrees }
        let latitudeTerm = sin((endLatitude - startLatitude) * radians / 2)
        let longitudeTerm = sin(longitudeDelta * radians / 2)
        let haversine = latitudeTerm * latitudeTerm
            + cos(startLatitude * radians) * cos(endLatitude * radians) * longitudeTerm * longitudeTerm
        let bounded = min(max(haversine, 0), 1)
        return 2 * earthRadiusMeters * atan2(bounded.squareRoot(), (1 - bounded).squareRoot())
    }
}
