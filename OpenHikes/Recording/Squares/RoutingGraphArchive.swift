//
//  RoutingGraphArchive.swift
//  OpenHikes
//
//  The graph the trail maker routes over, built ahead of time and kept on the
//  OpenHikes tile server: what an archive of it is called there, which tile
//  of it answers for a region, and what that tile is called on the way.
//
//  The maker routes a leg over trails and the roads that join them (see
//  ``TrailGraphHighway``), which the trail graph's squares in the public
//  database leave out: the roads were most of the planet, and ten thousand
//  times as many records as CloudKit is asked to hold. So that graph was a
//  question for Overpass, one z12 region at a time, from every phone drawing
//  a trail. It is built from the planet instead, by `Scripts/trail-cells.sh
//  build-routing`, as one PMTiles archive in the tile server's bucket, and
//  read a tile at a time through the server (`RoutingGraphServer`), with
//  Overpass behind it only where the server cannot answer.
//
//  ## A tile is a region
//
//  Each tile is one of the provider's regions, a slippy-map tile at
//  ``TrailGraphSquareGrid/regionZoom``, holding a ``TrailGraphSquareFile``
//  of every way whose box touches it, whole: the file the trail graph's
//  squares hold, read by the same library (``TrailGraphSquareLibrary``).
//  The squares in the public database are four levels up, because a record
//  there cost an upload and the roads were not in them. A tile here costs
//  nothing to hold, and a square four levels up with the roads in it was
//  the most a leg would ever download: measured on the planet of
//  2026-11-22, see `Scripts/trail-cells.sh` for the figures, the median
//  region is a few kilobytes and the one in a hundred over a few hundred.
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

    /// What every archive's name starts with on the server.
    static let namePrefix = "routing"

    /// The extension a tile is asked for under: the one the tile server's
    /// TileJSON gives an archive of tiles of no type it knows.
    static let tileExtension = "bin"

    /// Whether `name` is one this build asks the server for: `routing`, then
    /// hyphenated parts of lower-case letters and digits, as
    /// `routing-20261122-00` is. Nothing else, so a name off the network
    /// names an archive on that server and no other path.
    static func isArchiveName(_ name: String) -> Bool {
        let parts = name.split(separator: "-", omittingEmptySubsequences: false)
        return (1...maximumNameLength).contains(name.count)
            && parts.first == Substring(namePrefix)
            && parts.allSatisfy { part in
                !part.isEmpty && part.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber) }
            }
    }

    private static let maximumNameLength = 64
}

// MARK: - Where a tile is

nonisolated extension RoutingGraphArchive {
    /// The tile's path under the server's root: `<archive>/12/<x>/<y>.bin`.
    static func path(of tile: TrailGraphSquare, inArchive archive: String) -> String {
        "\(archive)/\(zoom)/\(tile.x)/\(tile.y).\(tileExtension)"
    }
}

// MARK: - What a tile is called on the way

nonisolated extension RoutingGraphArchive {
    private static var squarePrefix: String { "\(namePrefix)\(generation)" }
    private static let nameSeparator: Character = "_"
    private static let squareNamePartCount = 4

    /// The name the library asks the server's reader for a tile by, as it
    /// asks the public database for a square by its record name:
    /// `routing1_z12_<x>_<y>`.
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
