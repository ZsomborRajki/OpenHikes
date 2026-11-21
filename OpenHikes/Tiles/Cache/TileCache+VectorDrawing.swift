//
//  TileCache+VectorDrawing.swift
//  OpenHikes
//
//  The providers drawn from vector tiles: which loads are, and the
//  downloaded countries' half of a load. A tile a country holds is drawn out
//  of it before the network policy is asked, so it draws with no signal, and
//  before the tile server is, so a country costs the server nothing once it
//  is down. See ``OfflineCountryDrawing``. And a copy the cache drew before
//  the country that holds it was installed, or before the tile server's
//  manifest moved the provider to other archives (``VectorTileArchives``), is
//  not current, wherever it is kept, so the load draws it again from the
//  build there is now. Out of `TileCache.swift`, which is at the length the
//  linter allows.
//

import Foundation
import OpenHikesVectorTiles
import UIKit

nonisolated extension TileCache {
    /// The client that draws the tiles of `sources` off the tile server, and
    /// the drawing that takes them out of `countries` first: neither for a
    /// cache with no vector source, and no drawing for one given no
    /// countries.
    static func vectorDrawing(
        _ sources: VectorTileArchives?,
        _ session: URLSession,
        _ countries: OfflineCountryArchives?
    ) -> (VectorTileClient?, OfflineCountryDrawing?) {
        guard let sources else { return (nil, nil) }
        return (
            VectorTileClient(
                archives: sources,
                session: session,
                language: VectorMapWording.language,
                height: { VectorMapWording.height($0) }
            ),
            countries.map { OfflineCountryDrawing(sources: sources, archives: $0) }
        )
    }

    /// Reads the tile server's manifest, unless it was read in the last hour,
    /// so a build of the map that went up while the app was away is drawn
    /// from. Returns at once.
    func refreshVectorArchives() {
        vectorTiles?.archives.refresh()
    }

    /// Whether a load of `key` asks the OpenHikes tile server for a vector
    /// tile before the provider's raster template.
    func isDrawnFromVectorTiles(_ key: String) -> Bool {
        guard let vectorTiles, let named = TileCacheKey.named(key) else { return false }
        return vectorTiles.draws(named.providerID)
    }

    /// What a load of `key` takes from the tile server.
    enum VectorFetch {
        /// The tile, drawn and decoded.
        case tile(FetchedTile)
        /// The device reached no server, so the load fails without asking
        /// the raster template, which would fail the same way.
        case offline
        /// Nothing was drawn: the provider's raster template is asked.
        case fallBack
    }

    /// The tile server's answer for `key`, as a load takes it: a picture
    /// that cannot be decoded falls back as one that could not be drawn.
    func vectorFetch(forKey key: String) async -> VectorFetch {
        let drawn: Data
        let isProvisional: Bool
        switch await vectorDrawing(forKey: key) {
        case let .png(data): (drawn, isProvisional) = (data, false)
        case let .provisional(data): (drawn, isProvisional) = (data, true)
        case .offline: return .offline
        case .fallBack, nil: return .fallBack
        }
        guard let image = TileImage(data: drawn) else { return .fallBack }
        return .tile(FetchedTile(data: drawn, image: image, isProvisional: isProvisional))
    }

    /// The tile `key` names off the tile server, drawn, or what to do
    /// instead: the client's answer for the provider and tile the key names.
    /// `nil` for a cache with no vector source, and the raster template for
    /// a key of any other shape.
    func vectorDrawing(forKey key: String) async -> VectorTileClient.Drawing? {
        guard let vectorTiles else { return nil }
        guard let named = TileCacheKey.named(key) else { return .fallBack }
        return await vectorTiles.drawing(
            of: VectorTileAddress(z: named.z, x: named.x, y: named.y),
            for: named.providerID
        )
    }

    /// Whether the copy of `key` stored at `storedAt` was drawn before a
    /// downloaded country holding it was installed, or before its provider
    /// moved to other archives, and so is not current. The memory tier and
    /// the disk ask the same question, so a copy one turns away the other
    /// never hands back. Safe in the draw pass.
    func isRedrawn(_ key: String, storedAt: Date) -> Bool {
        if let vectorTiles, let named = TileCacheKey.named(key),
           vectorTiles.archives.redraws(named.providerID, drawnAt: storedAt) {
            return true
        }
        return countryTiles?.redraws(key, drawnAt: storedAt) == true
    }

    /// Whether a downloaded country holds the tile `key` names, and so draws
    /// it with no signal whether or not a copy is kept: what auto-save asks
    /// before it keeps one. Reads outlines and the archives' directories,
    /// never a tile. See ``OfflineCountryArchives/holds(_:deepest:)``.
    func isHeldByDownloadedCountry(_ key: String) -> Bool {
        countryTiles?.holds(key) == true
    }

    /// The tile `key` names, drawn out of a downloaded country and filed back
    /// in the tier it was found in, as a tile off the server would be, or
    /// `nil` where no country holds it. `.failed` only when the key was
    /// deleted while it was drawn.
    func countryTile(forKey key: String, wasDurable: Bool, token: MutationToken) -> TileLoadResult? {
        guard let drawn = countryTiles?.png(forKey: key), let image = TileImage(data: drawn) else { return nil }
        let fetched = FetchedTile(data: drawn, image: image)
        let tier: StorageTier = wasDurable ? .durable : .browsing
        return storeFetchedTile(fetched, forKey: key, in: tier, token: token) ? .loaded(image) : .failed
    }
}
