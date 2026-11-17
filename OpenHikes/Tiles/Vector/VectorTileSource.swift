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

import Foundation

/// One archive on the tile server: `<archive>/<z>/<x>/<y>.mvt`.
nonisolated struct VectorTileSource: Hashable, Sendable {
    /// The archive's address, without a trailing slash.
    let archiveURL: URL
    /// The deepest zoom the archive holds. A deeper tile is drawn from the
    /// one at this zoom that contains it, which carries every vertex the
    /// deeper one would.
    let maximumZ: Int

    func url(of tile: VectorTileAddress) -> URL {
        archiveURL.appending(path: "\(tile.z)/\(tile.x)/\(tile.y).mvt")
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
    /// Protomaps' basemap build of 17 November 2026: OpenStreetMap's data
    /// under the ODbL, to zoom 15, on `tiles.openhikes.app`.
    ///
    /// A new build goes up under a new name, and this changes with it. The
    /// server's cache keeps a tile for a day, so a build overwritten in place
    /// would be drawn from two builds at once.
    static let openHikesPlanet = Self(
        // swiftlint:disable:next force_unwrapping
        archiveURL: URL(string: "https://tiles.openhikes.app/planet-20261117")!,
        maximumZ: 15
    )
}
