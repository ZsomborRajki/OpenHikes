//
//  VectorTileSource.swift
//  OpenHikes
//
//  Where a provider's vector tiles come from: one PMTiles archive on the
//  OpenHikes tile server (#1481), served as Mapbox Vector Tiles in Protomaps'
//  URL scheme. The app draws them itself (`VectorTileRasterizer`) and hands
//  the picture to the raster pipeline, so the cache, auto-save and the
//  network policy treat it as any other tile. A provider with a vector
//  source keeps its raster template, as the fallback for every tile the
//  server cannot give (`VectorTileClient`).
//
//  A second archive, the extras, holds what OpenStreetMap Carto draws and
//  the basemap leaves out — car parks with no name, barriers, towers and
//  crosses, offices, an information point's type, one-way ways, the size of
//  each named area, the scree and heath of open mountains, parks and the
//  borders of protected areas, lifts and their stations, cliffs with the
//  side they fall away on, trees, the water that is not always there, what
//  picks a wood's or a wetland's symbols, the names of buildings, and the
//  huts, stations and summits Carto shows from a wider zoom — built from
//  the planet by `Scripts/vector-extras.sh`. Its tile is drawn into the
//  basemap's, where there is one.
//

import Foundation

/// One archive on the tile server: `<archive>/<z>/<x>/<y>.mvt`.
nonisolated struct VectorTileSource: Codable, Hashable, Sendable {
    /// The archive's address, without a trailing slash.
    let archiveURL: URL
    /// The deepest zoom the archive holds. A deeper tile is drawn from the
    /// one at this zoom that contains it, which carries every vertex the
    /// deeper one would.
    let maximumZ: Int
    /// The extras archive drawn into the same tiles, if there is one.
    var extras: Extras?

    /// An archive of what the basemap leaves out, cut on the same grid.
    struct Extras: Codable, Hashable, Sendable {
        let archiveURL: URL
        /// The widest zoom it holds anything at: a wider tile does not ask.
        let minimumZ: Int
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
nonisolated struct VectorTileAddress: Hashable, Sendable {
    let z: Int
    let x: Int
    let y: Int
}

nonisolated extension VectorTileSource {
    /// The OpenHikes planet on `tiles.openhikes.app`, as the manifest this
    /// build was made with names it: Protomaps' basemap, OpenStreetMap's data
    /// under the ODbL, with the extras. The tile cache draws from what the
    /// server's manifest names now (`VectorTileArchives`), which this is only
    /// the first of; a provider asks this whether it is drawn from vector
    /// tiles at all.
    static let openHikesPlanet = VectorTileArchiveManifest.bundled?.source(on: VectorTileArchives.server)
}
