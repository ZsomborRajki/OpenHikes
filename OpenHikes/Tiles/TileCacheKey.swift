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

    /// What a ``namespaced(providerID:z:x:y:)`` key names.
    struct Named: Equatable {
        let providerID: String
        let z: Int
        let x: Int
        let y: Int
    }

    /// The provider and tile `key` names, or `nil` for a key of any other
    /// shape. Anything after an `@` in the last part is ignored, as the keys
    /// the suites write still carry the scale a key once had.
    static func named(_ key: String) -> Named? {
        let parts = key.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 4,
              let z = Int(parts[1]),
              let x = Int(parts[2]),
              let y = Int(parts[3].prefix { $0 != "@" })
        else { return nil }
        return Named(providerID: String(parts[0]), z: z, x: x, y: y)
    }
}
