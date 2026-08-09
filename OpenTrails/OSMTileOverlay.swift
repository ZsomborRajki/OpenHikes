//
//  OSMTileOverlay.swift
//  OpenTrails
//
//  An MKTileOverlay backed by TileCache, plus tile-path math used for overzoom.
//

import Foundation
import MapKit

/// OpenStreetMap tile overlay that serves tiles through the shared cache.
nonisolated final class OSMTileOverlay: MKTileOverlay, @unchecked Sendable {
    private let cache = TileCache.shared

    /// Identifies the tile source, so cached tiles from different providers never
    /// collide. Set when the overlay is created for the selected provider.
    var providerID: String = TileProvider.default.id

    /// Synchronous cache hit, or nil. Used by the renderer's draw pass.
    func cachedImage(at path: MKTileOverlayPath) -> TileImage? {
        cache.memoryImage(forKey: cacheKey(for: path))
    }

    /// Asynchronously ensures the tile is cached (network if needed). Returns
    /// whether a tile is now available, so the renderer only redraws on success.
    func cacheTile(at path: MKTileOverlayPath) async -> Bool {
        let key = cacheKey(for: path)
        guard let image = await cache.loadTile(forKey: key, url: url(forTilePath: path)) else { return false }

        // Providers that disallow bulk downloading (e.g. OSM) still allow normal
        // browsing, so opportunistically keep tiles the user actually views —
        // never a synthetic prefetch, just what MapKit already asked for.
        if !TileProvider.provider(id: providerID).supportsBulkDownload {
            AutoSaveTileStore.shared.considerPersisting(key: key, z: path.z, x: path.x, y: path.y, image: image)
        }
        return true
    }

    /// Provider-namespaced cache key, so switching providers doesn't reuse tiles.
    private func cacheKey(for path: MKTileOverlayPath) -> String {
        "\(providerID)/\(path.cacheKey)"
    }
}

nonisolated extension MKTileOverlayPath {
    /// Stable string key (MKTileOverlayPath isn't Hashable).
    var cacheKey: String { "\(z)/\(x)/\(y)@\(contentScaleFactor)" }

    /// The tile one zoom level out that contains this one.
    var parent: MKTileOverlayPath {
        MKTileOverlayPath(x: x / 2, y: y / 2, z: z - 1, contentScaleFactor: contentScaleFactor)
    }

    /// Walks up to the tile at `targetZoom` that contains this one.
    func ancestor(atZoom targetZoom: Int) -> MKTileOverlayPath {
        var path = self
        while path.z > targetZoom { path = path.parent }
        return path
    }
}
