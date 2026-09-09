//
//  TileCacheKey.swift
//  OpenHikes
//

/// The one place a tile's cache key is spelled, for the renderer and the
/// offline downloader alike.
///
/// **Display scale is deliberately not part of a key.** No provider template
/// in ``TileProvider`` carries a scale or `@2x` placeholder, and neither
/// ``TileOverlay`` nor ``OfflineTileDownloader/Tile/url(from:)`` substitutes
/// one — both paths fetch the identical bytes from the identical URL. A scale
/// component could therefore only ever partition the cache without
/// partitioning its contents.
nonisolated enum TileCacheKey {
    static func path(
        z: Int,
        x: Int,
        y: Int
    ) -> String {
        "\(z)/\(x)/\(y)"
    }

    static func namespaced(
        providerID: String,
        z: Int,
        x: Int,
        y: Int
    ) -> String {
        "\(providerID)/\(path(z: z, x: x, y: y))"
    }
}
