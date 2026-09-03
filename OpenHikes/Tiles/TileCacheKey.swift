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

nonisolated extension TileCacheKey {
    /// The key a tile saved before the change above names now.
    ///
    /// Keys written by an older build end in `@1.0`, `@2.0` or `@3.0`, and the
    /// files on disk are named after them. Nothing looks those tiles up any
    /// more, so a manifest still listing them claims bytes the renderer can
    /// never read — see ``LegacyTileKeyMigration``, the one caller, for what
    /// is done about that.
    ///
    /// Conservative by construction: the suffix has to come after the last
    /// path separator *and* parse as a number, so a key that never carried a
    /// scale comes back untouched however it is spelled.
    static func withoutDisplayScale(_ key: String) -> String {
        guard let marker = key.lastIndex(of: "@"),
              marker > (key.lastIndex(of: "/") ?? key.startIndex),
              Double(key[key.index(after: marker)...]) != nil
        else { return key }
        return String(key[..<marker])
    }
}
