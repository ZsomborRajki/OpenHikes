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
//  ## The short way round the antimeridian
//
//  OpenStreetMap writes a way across the date line as it is mapped: a node at
//  179.9° and the next at −179.9°, about 21 km apart where the line crosses
//  Fiji. Read as plain numbers that step runs 359.8° round the world, through
//  Greenwich. Each step is read the short way instead, the only way a path is
//  walked (``turn(fromLongitude:to:)``), on both sides of the seam: the tool
//  files a way under the box of its steps read that way, which runs on past
//  ±180° and wraps round to the squares at the map's other edge, and
//  ``TrailGraphSquareLibrary`` finds a way crossing a region by the same
//  steps. The rule is written here, in the one file both compile, because
//  the two have to agree: a region is answered from its square alone, and in
//  a set that is the whole world a trail its square lacks is a trail that is
//  not there, with no reason to ask Overpass. A way that keeps off the line
//  is filed exactly as it was, unless it spans more than half the world:
//  the build took any such way for one across the line and filed it under
//  its nodes' squares alone, though the library reads one that never steps
//  across into every region between them, so it is now filed by its box.
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

    /// How many squares a side of the map is at `zoom`.
    static func tilesPerSide(atZoom zoom: Int = squareZoom) -> Int { 1 << zoom }
}

// MARK: - Which square

nonisolated extension TrailGraphSquareGrid {
    /// The square at `squareZoom` a region of the provider's grid lies in,
    /// or `nil` for one that is not a z12 tile. Every square here is
    /// ``squareZoom``'s but the trail maker's, which is a region itself:
    /// see ``RoutingGraphArchive``.
    static func square(forRegionX x: Int, y: Int, zoom: Int, squareZoom: Int = squareZoom) -> TrailGraphSquare? {
        guard zoom == regionZoom, (0...regionZoom).contains(squareZoom) else { return nil }
        let shift = regionZoom - squareZoom
        let count = 1 << regionZoom
        guard (0..<count).contains(x), (0..<count).contains(y) else { return nil }
        return TrailGraphSquare(x: x >> shift, y: y >> shift)
    }

    /// Every square at `zoom` a way touches, each once: what the tool files
    /// it under.
    ///
    /// The squares of the box of its nodes, each step from one node to the
    /// next read the short way round (``turn(fromLongitude:to:)``), so the
    /// box of a way across the antimeridian runs on past ±180° and holds
    /// every square the way crosses, whether or not a node of it is there.
    /// A way that never steps across the line is boxed as it is written.
    static func squares(
        touching nodes: [TrailGraphSquareFile.Node],
        coordinateScale: Int32,
        zoom: Int = squareZoom
    ) -> [TrailGraphSquare] {
        guard let first = nodes.first else { return [] }
        let scale = Double(coordinateScale)
        var south = Double(first.latitude) / scale
        var north = south
        var written = Double(first.longitude) / scale
        var west = written
        var east = written
        // Whole turns, so a longitude that is not moved is the one written.
        var turns = 0.0
        for node in nodes.dropFirst() {
            let latitude = Double(node.latitude) / scale
            let longitude = Double(node.longitude) / scale
            turns += turn(fromLongitude: written, to: longitude)
            written = longitude
            south = min(south, latitude)
            north = max(north, latitude)
            west = min(west, longitude + turns)
            east = max(east, longitude + turns)
        }
        return squares(touchingSouth: south, west: west, north: north, east: east, zoom: zoom)
    }

    /// Every square at `zoom` a box touches, each once.
    ///
    /// Its longitudes run west to east and may go on past ±180°, as a way's
    /// across the antimeridian do: what lies past the line is the squares at
    /// the map's other edge, so a box from 179.5° to 180.5° is the two
    /// columns either side of it. The line is the edge of the squares on
    /// both sides, so a box that reaches it touches both. Empty for a box
    /// that is not one.
    static func squares(
        touchingSouth south: Double,
        west: Double,
        north: Double,
        east: Double,
        zoom: Int = squareZoom
    ) -> [TrailGraphSquare] {
        guard south.isFinite, west.isFinite, north.isFinite, east.isFinite, south <= north, west <= east else {
            return []
        }
        let columns = Self.columns(west: west, east: east, zoom: zoom)
        // North is the smaller row: the slippy map counts down from the top.
        let rows = tileY(north, zoom: zoom)...tileY(south, zoom: zoom)
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

    /// The columns a box's longitudes reach, each once: its piece on each
    /// turn of the map it reaches, the map itself or the one past either
    /// edge, read as the map's own columns. A box that keeps off the line is
    /// one piece, the columns between its edges.
    private static func columns(west: Double, east: Double, zoom: Int) -> [Int] {
        guard east - west < fullTurnDegrees else { return Array(0..<tilesPerSide(atZoom: zoom)) }
        let firstTurn = Int(((west - halfTurnDegrees) / fullTurnDegrees).rounded(.up))
        let lastTurn = Int(((east + halfTurnDegrees) / fullTurnDegrees).rounded(.down))
        var columns: [Int] = []
        for turn in firstTurn...lastTurn {
            let shift = Double(turn) * fullTurnDegrees
            let piece = tileX(max(west - shift, -halfTurnDegrees), zoom: zoom)
                ... tileX(min(east - shift, halfTurnDegrees), zoom: zoom)
            columns += piece.filter { !columns.contains($0) }
        }
        return columns
    }
}

// MARK: - The short way round the antimeridian

nonisolated extension TrailGraphSquareGrid {
    /// The whole turn, in degrees, that `end` is moved by to stand the short
    /// way round from `start`, the longitude of the node before it on a way:
    /// 360° for a step written west from 179.9° to −179.9°, which runs 0.2°
    /// east across the antimeridian to 180.1°, −360° for one written east
    /// from −179.9° to 179.9°, and none for a step of half a turn or less,
    /// which is read as it is written.
    ///
    /// Both are OpenStreetMap's longitudes, each within ±180°, so a step
    /// crosses the antimeridian once at most. What the tool files a way by
    /// and the library reads a region's ways by — see this file's header.
    static func turn(fromLongitude start: Double, to end: Double) -> Double {
        let step = end - start
        if step > halfTurnDegrees { return -fullTurnDegrees }
        if step < -halfTurnDegrees { return fullTurnDegrees }
        return 0
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
              (0..<tilesPerSide()).contains(x), (0..<tilesPerSide()).contains(y)
        else { return nil }
        return TrailGraphSquare(x: x, y: y)
    }
}
