//
//  TileCache+VectorDrawing.swift
//  OpenHikes
//
//  The providers drawn from vector tiles: which loads are, and the
//  downloaded countries' half of a load. A tile a country holds is drawn out
//  of it before the network policy is asked, so it draws with no signal, and
//  before the tile server is, so a country costs the server nothing once it
//  is down. See ``OfflineCountryDrawing``. Out of `TileCache.swift`, which is
//  at the length the linter allows.
//

import Foundation
import UIKit

nonisolated extension TileCache {
    /// The client that draws the tiles of `sources` off the tile server, and
    /// the drawing that takes them out of `countries` first: neither for a
    /// cache with no vector source, and no drawing for one given no
    /// countries.
    static func vectorDrawing(
        _ sources: [String: VectorTileSource],
        _ session: URLSession,
        _ countries: OfflineCountryArchives?
    ) -> (VectorTileClient?, OfflineCountryDrawing?) {
        guard !sources.isEmpty else { return (nil, nil) }
        return (
            VectorTileClient(sources: sources, session: session),
            countries.map { OfflineCountryDrawing(sources: sources, archives: $0) }
        )
    }

    /// Whether a load of `key` asks the OpenHikes tile server for a vector
    /// tile before the provider's raster template.
    func isDrawnFromVectorTiles(_ key: String) -> Bool {
        vectorTiles?.draws(key) ?? false
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
