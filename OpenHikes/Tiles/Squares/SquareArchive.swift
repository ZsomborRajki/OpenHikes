//
//  SquareArchive.swift
//  OpenHikes
//
//  The pre-built squares on the OpenHikes tile server: the five sets, what
//  an archive of each is called there, which tile of it a square is, and
//  where that tile is asked for.
//
//  Four of the sets answer ahead of time a question that used to wait in
//  Overpass's queue: the day hikes the Community tab searches
//  (``TrailCellGrid``), the hiking-routes layer (``RouteSquareGrid``), the
//  places a place search offers (``PlaceSquareGrid``), and the trail graph
//  with the roads that join its trails (``RoutingGraphArchive``), which the
//  trail maker routes over and a recording is matched against. The fifth is
//  the heights a line with none is given (``ElevationSquareGrid``), which
//  were a billed service's. Each set is one PMTiles archive in the tile
//  server's bucket, built by `Scripts/trail-cells.sh` (the four from the
//  planet, the heights from the Copernicus DEM), and read a tile at a time
//  through the server (``SquareArchiveServer``).
//  The server's manifest names each set's archives under a list of its own,
//  newest first.
//
//  The squares used to be records in the public CloudKit database. An upload
//  there took hours for each environment and replaced the squares one record
//  at a time, so a refresh was rare, and a phone could read a square of the
//  new build beside one of the old. An archive goes up in minutes under a
//  new name, and the manifest moves every phone to it at once. The records
//  stay where they are for the builds that read them, and nothing here reads
//  them.
//
//  ## A tile is a square
//
//  A PMTiles archive keys its tiles by zoom, column and row. The trail
//  graph's tiles are the slippy-map tiles of its regions. The other four
//  sets are filed by squares of latitude and longitude, which no slippy-map
//  tile lines up with, so a square goes in at its own row and column, at the
//  shallowest zoom whose grid has room for every square of its kind: the
//  archive is a store of files by name, and the zoom says which grid. The
//  hiking-routes layer's four levels take four zooms. Such an archive is no
//  map, and nothing reads it as one; the tile server serves whatever tile it
//  holds.
//
//  ## Compiled twice
//
//  By the app, and by `Scripts/trail-cells.sh` into the tool that packs the
//  archives, so the two cannot disagree about where a square is. This file
//  imports Foundation and nothing of the app's but the grids the tool
//  compiles too, and says `nonisolated` on every declaration.
//

import Foundation

/// A tile of one of the archives: the zoom, column and row PMTiles keys it
/// by.
nonisolated struct SquareArchiveTile: Hashable, Sendable {
    var zoom: Int
    var x: Int
    var y: Int
}

/// One set of pre-built squares on the tile server.
nonisolated enum SquareArchive: String, CaseIterable, Sendable {
    /// The heights a line with none is given (``ElevationSquareGrid``).
    case elevation = "elevation"
    /// What a place search offers (``PlaceSquareGrid``).
    case places = "places"
    /// The hiking-routes layer (``RouteSquareGrid``), four levels of it.
    case routes = "routes"
    /// The trail graph, trails and the roads that join them: a tile is one of
    /// the graph provider's regions (``RoutingGraphArchive``).
    case routing = "routing"
    /// The Community tab's day hikes (``TrailCellGrid``).
    case trails = "trails"

    /// The list the tile server's manifest names this set's archives under,
    /// and what each archive's name begins with: `trails-20261122-00`.
    var listName: String { rawValue }

    /// The generation of the files its tiles hold: the set's own, which every
    /// square's name carries too. The manifest lists an archive with it, and
    /// an archive of another generation is one this build passes over.
    var generation: Int {
        switch self {
        case .routing: RoutingGraphArchive.generation
        case .trails: TrailCellGrid.generation
        case .routes: RouteSquareGrid.generation
        case .places: PlaceSquareGrid.generation
        case .elevation: ElevationSquareGrid.generation
        }
    }

    /// The zooms its tiles are at.
    var zooms: ClosedRange<Int> {
        switch self {
        case .routing:
            RoutingGraphArchive.zoom...RoutingGraphArchive.zoom
        case .trails:
            Self.trailsZoom...Self.trailsZoom
        case .routes:
            Self.routesZoom(of: .overview)...Self.routesZoom(of: .detail)
        case .places:
            Self.placesZoom...Self.placesZoom
        case .elevation:
            Self.elevationZoom...Self.elevationZoom
        }
    }

    /// The deepest of them: the one the tile server's TileJSON gives as an
    /// archive's `maxzoom`, which the manifest lists it with.
    var zoom: Int { zooms.upperBound }

    /// Whether `name` is one of this set's archives that this build asks the
    /// server for: the set's list name, then hyphenated parts of lower-case
    /// letters and digits, as `routing-20261122-00` is. Nothing else, so a
    /// name off the network names an archive on that server and no other
    /// path.
    func isArchiveName(_ name: String) -> Bool {
        let parts = name.split(separator: "-", omittingEmptySubsequences: false)
        return (1...Self.maximumNameLength).contains(name.count)
            && parts.first == Substring(listName)
            && parts.allSatisfy { part in
                !part.isEmpty && part.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber) }
            }
    }

    /// The extension a tile is asked for under: the one the tile server's
    /// TileJSON gives an archive of tiles of no type it knows.
    static let tileExtension = "bin"

    /// The tile's path under the server's root: `<archive>/<z>/<x>/<y>.bin`.
    static func path(of tile: SquareArchiveTile, inArchive archive: String) -> String {
        "\(archive)/\(tile.zoom)/\(tile.x)/\(tile.y).\(tileExtension)"
    }

    private static let maximumNameLength = 64
}

// MARK: - Which tile a square is

nonisolated extension SquareArchive {
    /// The tile of this set's archive that holds the square named `name`, or
    /// `nil` for a name that is not one of this generation's squares.
    func tile(named name: String) -> SquareArchiveTile? {
        switch self {
        case .routing:
            return RoutingGraphArchive.tile(named: name).map { tile in
                SquareArchiveTile(zoom: RoutingGraphArchive.zoom, x: tile.x, y: tile.y)
            }

        case .trails:
            return TrailCellGrid.cell(named: name).map { cell in
                SquareArchiveTile(zoom: Self.trailsZoom, x: cell.column, y: cell.row)
            }

        case .routes:
            return RouteSquareGrid.square(named: name).map { square in
                SquareArchiveTile(zoom: Self.routesZoom(of: square.level), x: square.column, y: square.row)
            }

        case .places:
            return PlaceSquareGrid.square(named: name).map { square in
                SquareArchiveTile(zoom: Self.placesZoom, x: square.column, y: square.row)
            }

        case .elevation:
            return ElevationSquareGrid.square(named: name).map { square in
                SquareArchiveTile(zoom: Self.elevationZoom, x: square.column, y: square.row)
            }
        }
    }

    /// The name of the square a tile of this set's archive holds, or `nil`
    /// for a tile that is no square of it: what the tool reads an archive
    /// back by.
    func name(of tile: SquareArchiveTile) -> String? {
        let name: String? = switch self {
        case .routing:
            tile.zoom == RoutingGraphArchive.zoom
                ? RoutingGraphArchive.squareName(for: TrailGraphSquare(x: tile.x, y: tile.y))
                : nil

        case .trails:
            tile.zoom == Self.trailsZoom
                ? TrailCellGrid.recordName(for: TrailCell(row: tile.y, column: tile.x))
                : nil

        case .routes:
            RouteSquareLevel.shallowestFirst.first(where: { Self.routesZoom(of: $0) == tile.zoom }).map { level in
                RouteSquareGrid.recordName(for: RouteSquare(level: level, row: tile.y, column: tile.x))
            }

        case .places:
            tile.zoom == Self.placesZoom
                ? PlaceSquareGrid.recordName(for: PlaceSquare(row: tile.y, column: tile.x))
                : nil

        case .elevation:
            tile.zoom == Self.elevationZoom
                ? ElevationSquareGrid.recordName(for: ElevationSquare(row: tile.y, column: tile.x))
                : nil
        }
        // Only a name that reads back as this very tile: one past the grid's
        // last row or column names no square.
        guard let name, self.tile(named: name) == tile else { return nil }
        return name
    }

    /// The day hikes' zoom: a quarter-degree grid, 1,440 squares round.
    private static var trailsZoom: Int {
        zoom(holdingRows: TrailCellGrid.rowCount, columns: TrailCellGrid.columnCount)
    }

    /// The places' zoom: a one-degree grid, 360 squares round.
    private static var placesZoom: Int {
        zoom(holdingRows: PlaceSquareGrid.rowCount, columns: PlaceSquareGrid.columnCount)
    }

    /// The heights' zoom: an eighth-degree grid, 2,880 squares round, rows
    /// from the North Pole. A degree is the 8 × 8 tiles under one tile of
    /// zoom 9, so its squares are one run of tile ids.
    static var elevationZoom: Int {
        zoom(holdingRows: ElevationSquareGrid.rowCount, columns: ElevationSquareGrid.columnCount)
    }

    /// A hiking-routes level's zoom: 7 for the 4° overview, then 9, 10 and
    /// 11 for the 1°, half-degree and quarter-degree squares, one zoom a
    /// level.
    private static func routesZoom(of level: RouteSquareLevel) -> Int {
        zoom(holdingRows: RouteSquareGrid.rowCount(of: level), columns: RouteSquareGrid.columnCount(of: level))
    }

    /// The shallowest zoom whose grid, `2^z` tiles each way, has room for
    /// every row and column.
    private static func zoom(holdingRows rows: Int, columns: Int) -> Int {
        var zoom = 0
        while 1 << zoom < max(rows, columns) {
            zoom += 1
        }
        return zoom
    }
}
