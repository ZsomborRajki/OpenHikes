//
//  TileOverlay.swift
//  OpenHikes
//
//  An MKTileOverlay backed by TileCache, plus tile-path math used for overzoom.
//

import Foundation
import MapKit

/// Raster tile overlay for the selected provider, served through ``TileCache``.
///
/// `@unchecked` because of the superclass, not because of any state of its
/// own: `MKTileOverlay` is not declared `Sendable` by the SDK, while every
/// stored property below is an immutable `let`.
nonisolated final class TileOverlay: MKTileOverlay, @unchecked Sendable {
    /// The cache tiles are served from and filed into. Injectable so a test
    /// can hand over one wired to a stub transport and its own directories;
    /// the app always gets the shared one.
    let cache: TileCache

    /// Identifies the tile source, so cached tiles from different providers never
    /// collide.
    ///
    /// `let`, and taken in the initializer, because this type is
    /// `@unchecked Sendable` and this property is read off the main thread on
    /// every tile load (through ``cacheKey(for:)``, from ``cacheTile(at:)``'s
    /// background task). As a `var` it was safe only by convention — assigned
    /// once immediately after construction and never again — with nothing
    /// stopping a later change from mutating it after publication, which would
    /// be a silent data race *and* would start filing tiles under the wrong
    /// provider. Switching providers builds a new overlay anyway
    /// (`MapView.applyTileSource`), so there was never a reason for it to move.
    let providerID: String

    /// Where a drawn tile is offered for auto-save. Injectable alongside
    /// ``cache`` so a test's overlay can't claim tiles for whatever hike the
    /// app's singleton happens to have active.
    let autoSaveStore: AutoSaveTileStore

    init(
        providerID: String,
        urlTemplate: String?,
        cache: TileCache = .shared,
        autoSaveStore: AutoSaveTileStore = .shared
    ) {
        self.providerID = providerID
        self.cache = cache
        self.autoSaveStore = autoSaveStore
        super.init(urlTemplate: urlTemplate)
    }

    /// Synchronous cache hit, or nil. Used by the renderer's draw pass.
    func cachedImage(at path: MKTileOverlayPath) -> TileImage? {
        cache.memoryImage(forKey: cacheKey(for: path))
    }

    /// Asynchronously ensures the tile is cached (network if needed), keeping
    /// policy suppression distinct from a failed request for renderer backoff.
    func cacheTile(at path: MKTileOverlayPath) async -> TileLoadDisposition {
        let key = cacheKey(for: path)
        let result = await cache.loadTileResult(forKey: key, url: url(forTilePath: path))
        guard case .loaded = result else { return result.disposition }

        // Opportunistically keep tiles the user actually views — never a
        // synthetic prefetch, just what MapKit already asked for. Runs for
        // every provider: it's how OSM (which disallows bulk downloading)
        // saves anything at all, and it also fills gaps a bulk download left
        // (e.g. an area zoomed into that the bulk pass didn't cover) for
        // providers that support both. Takes only the key: the tile's bytes are
        // in the cache the load above just populated, and get moved, not re-encoded.
        autoSaveStore.considerPersisting(key: key, z: path.z, x: path.x, y: path.y)
        return .loaded
    }

    /// When the tile server last said this tile may be asked for again, if it
    /// said anything and that moment has not passed.
    ///
    /// A separate call rather than part of ``cacheTile(at:)``'s result,
    /// because the two are keyed differently: the renderer's failure log is
    /// keyed by tile path while the cache files advice under the
    /// provider-namespaced key, and this is the only type that knows both.
    func retryDeadline(at path: MKTileOverlayPath) -> ContinuousClock.Instant? {
        cache.retryDeadline(forKey: cacheKey(for: path))
    }

    /// Provider-namespaced cache key, so switching providers doesn't reuse tiles.
    private func cacheKey(for path: MKTileOverlayPath) -> String {
        TileCacheKey.namespaced(
            providerID: providerID,
            z: path.z,
            x: path.x,
            y: path.y,
            scale: path.contentScaleFactor
        )
    }
}

nonisolated extension MKTileOverlayPath {
    /// Stable string key (MKTileOverlayPath isn't Hashable).
    var cacheKey: String {
        TileCacheKey.path(
            z: z,
            x: x,
            y: y,
            scale: contentScaleFactor
        )
    }

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
