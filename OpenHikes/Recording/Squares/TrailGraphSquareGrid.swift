//
//  TrailGraphSquareGrid.swift
//  OpenHikes
//
//  The squares OpenStreetMap's trails are filed in ahead of time for the trail
//  graph, what each one's record is called, and which square answers for one
//  of the graph's regions.
//
//  The graph a recording is matched against, a hike's surface and difficulty
//  are read from and a route is coloured by was a question put to Overpass,
//  one z12 tile at a time — see ``OverpassTrailGraphProvider``. Like the day
//  hikes' search (see ``TrailCellGrid``), the wait was the public server's
//  queue, so the trails are built ahead of time: `Scripts/trail-cells.sh
//  build-graph` reads a planet file and files every trail under the squares
//  of this grid it reaches, kept in the public database one record a square.
//  See ``TrailGraphSquareLibrary`` for the reading and ``TrailGraphSquareFile``
//  for what one square holds.
//
//  ## Trails, and not the roads that join them
//
//  The graph Overpass answers with holds roads as well as trails, because the
//  trail maker routes over both (see ``TrailGraphHighway``). Those roads were
//  most of the planet: measured on planet-261109, the ways the graph keeps
//  were 263.5 million, holding 2.5 billion nodes and 19.7 GB of OpenStreetMap
//  data, and the trails among them 85.5 million ways, 1.0 billion nodes and
//  6.9 GB. Everything but the maker reads trails alone, so the squares hold
//  trails alone, and the maker keeps asking Overpass for the graph it routes
//  over — see `OpenHikesModel.makeTrailGraphProviders()`.
//
//  ## Slippy-map squares, so a region is in exactly one
//
//  A square is a tile of the slippy map at ``squareZoom``, which is the
//  graph's own grid a few levels up: every z12 region the provider asks about
//  lies in exactly one square, and a square answers for all of the regions
//  inside it. The tile arithmetic is spelled here rather than borrowed from
//  ``SlippyTileMath``, which the tool cannot compile, and
//  `TrailGraphSquareGridTests` holds the two to one answer.
//
//  A way is filed under every square its box touches, whole: the provider's
//  Overpass query answers a region with every way that crosses it, from end to
//  end, so a square has to hold every way that can cross any of its regions.
//
//  Measured on planet-261109 at zoom 10: 82.8 million trails that may be
//  walked, in 124,279 squares and 5.0 GB, the median square 5.4 KB, one in a
//  hundred over 627 KB, and the largest, over Paris, 6.0 MB for 223,790
//  trails. The square around Berchtesgaden is 683 KB for 8,891. A square is
//  about 27 km across at 47°N, so the nine regions a recording keeps around
//  the hiker lie in one to four squares. Zoom 9 was measured too: 37,778
//  squares, the largest about 9 MB, a third of the records to upload for four
//  times the bytes every recording downloads.
//
//  ## Compiled twice
//
//  By the app, which reads the squares, and by `Scripts/trail-cells.sh` into
//  the tool that writes them, for the reason ``TrailCellGrid`` gives: this
//  file imports Foundation and nothing of the app's, and says `nonisolated` on
//  every declaration.
//

import Foundation

/// One square of the trail graph's grid: a slippy-map tile at
/// ``TrailGraphSquareGrid/squareZoom``.
nonisolated struct TrailGraphSquare: Hashable, Sendable {
    var x: Int
    var y: Int
}

/// Where the trail graph's squares are, and what they are called.
nonisolated enum TrailGraphSquareGrid {
    /// The generation of ``TrailGraphSquareFile`` these records hold, and part
    /// of every record's name, for the reason ``TrailCellGrid/generation`` is.
    static let generation = 1

    /// The zoom of the slippy-map tiles a square is.
    static let squareZoom = 10

    /// The zoom of the provider's regions, which a square answers for.
    static let regionZoom = 12

    /// The latitude the slippy map stops at, `Mercator.latitudeLimit`'s
    /// figure.
    static let latitudeLimit = 85.0511287798066

    private static let halfTurnDegrees: Double = 180
    private static let fullTurnDegrees: Double = 360

    static var tilesPerSide: Int { 1 << squareZoom }
}

// MARK: - Which square

nonisolated extension TrailGraphSquareGrid {
    /// The square a region of the provider's grid lies in, or `nil` for one
    /// that is not a z12 tile.
    static func square(forRegionX x: Int, y: Int, zoom: Int) -> TrailGraphSquare? {
        guard zoom == regionZoom else { return nil }
        let shift = regionZoom - squareZoom
        let count = 1 << regionZoom
        guard (0..<count).contains(x), (0..<count).contains(y) else { return nil }
        return TrailGraphSquare(x: x >> shift, y: y >> shift)
    }

    /// Every square a box touches, each once: what a way is filed under.
    ///
    /// The box is the plain minimum and maximum of a way's points. One that
    /// spans more than half the world is a way across the antimeridian read
    /// the long way round, and is filed by its points' own squares instead —
    /// see `TrailGraphSquareBuild`.
    static func squares(
        touchingSouth south: Double,
        west: Double,
        north: Double,
        east: Double
    ) -> [TrailGraphSquare] {
        guard south.isFinite, west.isFinite, north.isFinite, east.isFinite, south <= north, west <= east else {
            return []
        }
        let columns = tileX(west, zoom: squareZoom)...tileX(east, zoom: squareZoom)
        // North is the smaller row: the slippy map counts down from the top.
        let rows = tileY(north, zoom: squareZoom)...tileY(south, zoom: squareZoom)
        return rows.flatMap { row in
            columns.map { TrailGraphSquare(x: $0, y: row) }
        }
    }

    /// The tile column a longitude falls in at `zoom`, inside the grid.
    static func tileX(_ longitude: Double, zoom: Int) -> Int {
        let count = 1 << zoom
        let column = Int(((longitude + halfTurnDegrees) / fullTurnDegrees * Double(count)).rounded(.down))
        return min(max(column, 0), count - 1)
    }

    /// The tile row a latitude falls in at `zoom`, inside the grid.
    ///
    /// The slippy map's projection, in the form `Mercator.unitY(latitude:)`
    /// writes it, so the two cannot round a point on an edge differently.
    static func tileY(_ latitude: Double, zoom: Int) -> Int {
        let count = 1 << zoom
        let clamped = min(max(latitude, -latitudeLimit), latitudeLimit)
        let sine = sin(clamped * .pi / halfTurnDegrees)
        let unit = 0.5 - log((1 + sine) / (1 - sine)) / (4 * .pi)
        return min(max(Int((unit * Double(count)).rounded(.down)), 0), count - 1)
    }
}

// MARK: - What a square's record is called

nonisolated extension TrailGraphSquareGrid {
    private static var namePrefix: String { "graph\(generation)" }
    private static let nameSeparator: Character = "_"
    private static let namePartCount = 4

    /// The name of the record that says what this generation's squares cover,
    /// as ``TrailCellGrid/manifestRecordName`` does for the day hikes'.
    static var manifestRecordName: String { "\(namePrefix)\(nameSeparator)manifest" }

    /// The name `square`'s record is saved under and fetched by — a storage
    /// contract, like every record name this app derives.
    static func recordName(for square: TrailGraphSquare) -> String {
        [namePrefix, "z\(squareZoom)", String(square.x), String(square.y)]
            .joined(separator: String(nameSeparator))
    }

    /// The square a record name is for, or `nil` for a name that is not one
    /// of this generation's squares.
    static func square(named name: String) -> TrailGraphSquare? {
        let parts = name.split(separator: nameSeparator, omittingEmptySubsequences: false)
        guard parts.count == namePartCount, parts[0] == namePrefix, parts[1] == "z\(squareZoom)",
              let x = Int(parts[2]), let y = Int(parts[3]),
              (0..<tilesPerSide).contains(x), (0..<tilesPerSide).contains(y)
        else { return nil }
        return TrailGraphSquare(x: x, y: y)
    }
}
