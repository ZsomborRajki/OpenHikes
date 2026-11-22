//
//  RoutingGraphArchive.swift
//  OpenHikes
//
//  The trail graph, built ahead of time and kept on the OpenHikes tile
//  server: the zoom and generation of its archive, and what a tile of it is
//  called on the way. ``SquareArchive`` names the archive and says where a
//  tile is asked for, as it does for every set of squares on the server.
//
//  The graph is every trail and every road that joins trails (see
//  ``TrailGraphHighway``): the trail maker routes a leg over both, and a
//  recording, a hike's breakdowns and the route's colours read the trails
//  of it, as they read an Overpass answer, which holds the roads too. It
//  was a question for Overpass, one z12 region at a time, from every phone
//  drawing a trail or recording one. It is built from the planet instead, by
//  `Scripts/trail-cells.sh build-routing`, as one PMTiles archive in the tile
//  server's bucket, and read a tile at a time through the server
//  (``SquareArchiveServer``), with Overpass behind it only where the server
//  cannot answer.
//
//  ## A tile is a region
//
//  Each tile is one of the provider's regions, a slippy-map tile at
//  ``TrailGraphSquareGrid/regionZoom``, holding a ``TrailGraphSquareFile``
//  of every way whose box touches it, whole, read by
//  ``TrailGraphSquareLibrary``. The trail graph's squares in the public
//  database, which installed builds before this one read, are four levels
//  up and hold the trails alone, because a record there cost an upload and
//  the roads were most of the planet. A tile here costs nothing to hold, and
//  a square four levels up with the roads in it is what a region would
//  download. Measured on the planet of 2026-11-22: 1.78 million tiles and
//  18.7 GB, the median tile 3.4 KB, one in a hundred over 118 KB, and the
//  largest, over Paris, 1.7 MB for 56,925 ways. Filed four levels up, the
//  same ways were 141,281 squares and 14.5 GB, the median 15 KB, one in a
//  hundred over 1.4 MB, and the largest 10.6 MB. The tiles hold 29% more in
//  all, for a quarter of the median download and a sixth of the largest.
//
//  ## Compiled twice
//
//  By the app, which reads the archive, and by `Scripts/trail-cells.sh` into
//  the tool that writes it, for the reason ``TrailGraphSquareGrid`` gives:
//  this file imports Foundation and nothing of the app's, and says
//  `nonisolated` on every declaration.
//

import Foundation

nonisolated enum RoutingGraphArchive {
    /// The zoom of the archive's tiles: the provider's regions'.
    static let zoom = TrailGraphSquareGrid.regionZoom

    /// The format of the files its tiles hold, and the generation the tile
    /// server's manifest lists an archive under: an archive of another
    /// generation is one this build does not read, and passes over.
    static let generation = TrailGraphSquareGrid.generation
}

// MARK: - What a tile is called on the way

nonisolated extension RoutingGraphArchive {
    private static var squarePrefix: String { "\(SquareArchive.routing.listName)\(generation)" }
    private static let nameSeparator: Character = "_"
    private static let squareNamePartCount = 4

    /// The name the library asks the server's reader for a tile by, as every
    /// set's squares are asked for by name: `routing1_z12_<x>_<y>`.
    static func squareName(for tile: TrailGraphSquare) -> String {
        [squarePrefix, "z\(zoom)", String(tile.x), String(tile.y)].joined(separator: String(nameSeparator))
    }

    /// The tile a name is for, or `nil` for a name that is not one of this
    /// generation's tiles.
    static func tile(named name: String) -> TrailGraphSquare? {
        let parts = name.split(separator: nameSeparator, omittingEmptySubsequences: false)
        let side = TrailGraphSquareGrid.tilesPerSide(atZoom: zoom)
        guard parts.count == squareNamePartCount, parts[0] == squarePrefix, parts[1] == "z\(zoom)",
              let x = Int(parts[2]), let y = Int(parts[3]),
              (0..<side).contains(x), (0..<side).contains(y)
        else { return nil }
        return TrailGraphSquare(x: x, y: y)
    }
}
