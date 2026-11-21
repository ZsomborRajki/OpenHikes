//
//  VectorTileSource.swift
//  OpenHikesVectorTiles
//
//  Where a provider's vector tiles come from: one PMTiles archive on a tile
//  server, served as Mapbox Vector Tiles in Protomaps' URL scheme. OpenHikes'
//  server is `tiles.openhikes.app` (#1481). The tiles are drawn here
//  (`VectorTileRasterizer`) and the picture handed to the host's raster
//  pipeline, so its cache, auto-save and network policy treat it as any
//  other tile. In OpenHikes a provider with a vector source keeps its raster
//  template, as the fallback for every tile the server cannot give
//  (`VectorTileClient`).
//
//  A second archive, the extras, holds what OpenStreetMap Carto draws and
//  the basemap leaves out — car parks with no name, barriers, towers and
//  crosses, offices, an information point's type, one-way ways, the size of
//  each named area, the scree and heath of open mountains, parks and the
//  borders of protected areas, lifts and their stations, every path and
//  service road with what Carto draws it by, cliffs with the side they
//  fall away on, trees, the water that is not always there, what
//  picks a wood's or a wetland's symbols, the names of buildings, and the
//  huts, stations and summits Carto shows from a wider zoom — built from
//  the planet by `Scripts/vector-extras.sh`. Its tile is drawn into the
//  basemap's, where there is one.
//

import Foundation

/// One archive on the tile server: `<archive>/<z>/<x>/<y>.mvt`.
public struct VectorTileSource: Codable, Hashable, Sendable {
    /// The archive's address, without a trailing slash.
    public let archiveURL: URL
    /// The deepest zoom the archive holds. A deeper tile is drawn from the
    /// one at this zoom that contains it, which carries every vertex the
    /// deeper one would.
    public let maximumZ: Int
    /// The extras archive drawn into the same tiles, if there is one.
    public var extras: Extras?

    /// An archive of what the basemap leaves out, cut on the same grid.
    public struct Extras: Codable, Hashable, Sendable {
        public let archiveURL: URL
        /// The widest zoom it holds anything at: a wider tile does not ask.
        public let minimumZ: Int

        public init(archiveURL: URL, minimumZ: Int) {
            self.archiveURL = archiveURL
            self.minimumZ = minimumZ
        }
    }

    public init(archiveURL: URL, maximumZ: Int, extras: Extras? = nil) {
        self.archiveURL = archiveURL
        self.maximumZ = maximumZ
        self.extras = extras
    }

    func url(of tile: VectorTileAddress) -> URL {
        archiveURL.appending(path: "\(tile.z)/\(tile.x)/\(tile.y).mvt")
    }

    /// Where the extras for `tile`, an archive tile, are, or `nil` where
    /// there are none to ask for.
    func extrasURL(of tile: VectorTileAddress) -> URL? {
        guard let extras, tile.z >= extras.minimumZ else { return nil }
        return extras.archiveURL.appending(path: "\(tile.z)/\(tile.x)/\(tile.y).mvt")
    }

    /// The archive tile `tile` is drawn from: itself, or the one at
    /// ``maximumZ`` that contains it.
    func dataTile(for tile: VectorTileAddress) -> VectorTileAddress {
        let shift = max(tile.z - maximumZ, 0)
        return VectorTileAddress(z: tile.z - shift, x: tile.x >> shift, y: tile.y >> shift)
    }
}

/// A tile by zoom, column and row, in the slippy-map grid every tile source
/// here shares.
public struct VectorTileAddress: Hashable, Sendable {
    public let z: Int
    public let x: Int
    public let y: Int

    public init(z: Int, x: Int, y: Int) {
        self.z = z
        self.x = x
        self.y = y
    }
}
