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
///
/// It did exactly that. The key used to end in `@\(scale)`, and the two paths
/// read that scale from different runtime sources: the renderer from
/// `MKTileOverlayPath.contentScaleFactor`, which MapKit documents as
/// "typically either 1.0 or 2.0" and never raises to 3, and the downloader
/// from SwiftUI's `displayScale`, which is 3.0 on every Plus/Pro/Pro Max. On
/// those devices a download wrote `…@3.0` and the map looked up `…@2.0`, so a
/// hike downloaded for offline use was fetched again tile by tile while the
/// storage row still reported it as saved. Removing the component is what
/// makes that class of drift unrepresentable rather than merely tested for.
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
