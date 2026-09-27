//
//  OfflineTileDownloader+Planning.swift
//  OpenHikes
//

import CoreLocation
import Foundation
import OpenHikesData

nonisolated extension OfflineTileDownloader {
    nonisolated struct Tile: Sendable {
        let z: Int
        let x: Int
        let y: Int

        func url(from template: String) -> URL? {
            let filled = template
                .replacingOccurrences(of: "{z}", with: String(z))
                .replacingOccurrences(of: "{x}", with: String(x))
                .replacingOccurrences(of: "{y}", with: String(y))
            return URL(string: filled)
        }

        func cacheKey(providerID: String) -> String {
            TileCacheKey.namespaced(
                providerID: providerID,
                z: z,
                x: x,
                y: y
            )
        }
    }

    /// What a download sets out to save, and the box it was planned over.
    ///
    /// The box travels with the tiles because it is what every record the run
    /// claims is stamped with — see ``OfflineDownloadRecord/footprint``. Read
    /// back off the hike when the run ends, it would describe whatever the
    /// trail had been redrawn to in the meantime rather than the tiles this
    /// run actually fetched.
    nonisolated struct Plan: Sendable {
        let tiles: [Tile]
        /// `nil` only for an empty route, which plans no tiles either.
        let footprint: OfflineDownloadFootprint?
    }

    /// `@concurrent` so a tap that starts a download does its O(tileBudget)
    /// planning on the concurrent executor while staying in the download
    /// task — cancelling that task stops planning immediately.
    @concurrent
    static func plannedTiles(
        for route: [RouteCoordinate],
        maxZoom: Int,
        providerID: String
    ) async throws(CancellationError) -> Plan {
        assertOffMainThread(
            "Offline-download planning must stay off the main thread"
        )
        // The one thing that runs before a download commits to any network
        // traffic.
        let box = try TileBoundingBox(route: route.clCoordinates())
        let result = tiles(
            covering: box,
            minZoom: minZoom,
            maxZoom: maxZoom,
            budget: tileBudget(forProviderID: providerID)
        )
        guard !Task.isCancelled else { throw CancellationError() }
        return Plan(tiles: result, footprint: box?.footprint)
    }

    /// What a previous run of the same download already saved and claimed.
    ///
    /// Read straight off the hike's partial records rather than re-derived
    /// from the route, which is what makes it cheap enough to ask on the main
    /// actor at the moment of the tap: a partial record lists its exact keys,
    /// and a *complete* one for this provider and depth means there is nothing
    /// left to fetch at all — reported here as the full grid being outstanding
    /// of nothing, since `plannedTiles` will then filter every tile away and
    /// the run finishes without a request.
    ///
    /// Matched on provider **and** depth, because neither alone is the same
    /// download: tiles are namespaced by provider, and a shallower previous
    /// run saved none of the deeper levels this one wants.
    static func resumableKeys(
        from records: [OfflineDownloadRecord],
        source: ActiveTileSource
    ) -> Set<String> {
        var keys = Set<String>()
        for record in records
        where record.providerID == source.providerID && record.maxZoom == source.maximumZ {
            guard !record.savedTileKeys.isEmpty else {
                // A complete record. Re-deriving its grid here would be the
                // O(tileBudget) trig work this function exists to avoid, and
                // it is not needed: the button that starts a download is not
                // offered for a map that is already whole, and a run started
                // anyway plans the grid and finds every tile present.
                continue
            }
            keys.formUnion(record.savedTileKeys)
        }
        return keys
    }

    /// The cache keys every tile a download of `route` would produce for the
    /// given provider and depth — so stored tiles can be measured and removed
    /// after the fact. Deterministic: recomputing yields exactly the saved set.
    static func tileKeys(
        for route: [CLLocationCoordinate2D],
        providerID: String,
        providerMaxZoom: Int,
        maxZoom: Int
    ) -> [String] {
        tileKeys(
            in: TileBoundingBox(route: route),
            providerID: providerID,
            providerMaxZoom: providerMaxZoom,
            maxZoom: maxZoom
        )
    }

    /// The same, for a download planned over `box` — the spelling a record
    /// that kept its ``OfflineDownloadRecord/footprint`` is recomputed with.
    static func tileKeys(
        in box: TileBoundingBox?,
        providerID: String,
        providerMaxZoom: Int,
        maxZoom: Int
    ) -> [String] {
        let clamped = min(max(maxZoom, minZoom), providerMaxZoom)
        return tiles(
            covering: box,
            minZoom: minZoom,
            maxZoom: clamped,
            budget: tileBudget(forProviderID: providerID)
        ).map { tile in
            tile.cacheKey(providerID: providerID)
        }
    }

    /// A complete record is recomputed from the box it was planned over, not
    /// from `route`: the trail may have been redrawn since, and the grid of
    /// the line it has now is tiles nobody fetched — see
    /// ``OfflineDownloadRecord/footprint``. `route` stands in only for a
    /// record written before the box was kept.
    ///
    /// Enumerating tiles across every recorded download is real CPU work (trig
    /// per tile, up to `tileBudget` tiles each), so callers that do this
    /// repeatedly — re-measuring storage as auto-save drains in new keys —
    /// must not run it on the main thread.
    ///
    /// Cancellable: outside a task `Task.isCancelled` is always `false`, so a
    /// synchronous caller never sees the throw.
    static func storedTileKeys(
        route: [CLLocationCoordinate2D],
        offlineDownloads: [OfflineDownloadRecord]
    ) throws(CancellationError) -> [String] {
        assertOffMainThread(
            "storedTileKeys(route:offlineDownloads:) does O(tileBudget) trig work " +
            "per download record — call it off the main thread"
        )
        guard !offlineDownloads.isEmpty else { return [] }
        // Re-derived rather than stored, and re-derived again every time
        // storage is measured — which is the cost worth watching here, not the
        // one-off a download pays.
        var keys = Set<String>()
        for record in offlineDownloads {
            // Every record, not every nth: each one enumerates up to a tile
            // budget's worth of grid — and one without a footprint re-walks
            // the whole route first — so a sizeable unit of work sits between
            // consecutive checks even when there are only two records.
            guard !Task.isCancelled else { throw CancellationError() }
            if !record.savedTileKeys.isEmpty {
                keys.formUnion(record.savedTileKeys)
                continue
            }
            let provider = TileProvider.provider(id: record.providerID)
            keys.formUnion(
                tileKeys(
                    in: record.footprint.map(TileBoundingBox.init) ?? TileBoundingBox(route: route),
                    providerID: record.providerID,
                    providerMaxZoom: provider.maximumZ,
                    maxZoom: record.maxZoom
                )
            )
        }
        return Array(keys)
    }

    /// Enumerates the tiles covering a route's bounding box from the overview
    /// zoom up, stopping before a zoom level that would exceed the tile budget.
    private static func tiles(
        covering box: TileBoundingBox?,
        minZoom: Int,
        maxZoom: Int,
        budget: Int
    ) -> [Tile] {
        guard maxZoom >= minZoom, let box else { return [] }

        // A route too sprawling for even the overview zoom to fit the budget
        // gets a shallower overview rather than nothing at all: the budget has
        // to bind here too, but returning empty would surface as "Nothing to
        // save." for a route that has plenty worth saving. Each level down is a
        // quarter of the tiles, so this bottoms out within a level or two — and
        // at zoom 0 the whole world is one tile.
        var overviewZoom = minZoom
        while overviewZoom > 0, box.tileCount(at: overviewZoom) > budget {
            overviewZoom -= 1
        }

        var tiles: [Tile] = []
        var running = 0
        for z in overviewZoom...maxZoom {
            let count = box.tileCount(at: z)
            guard running + count <= budget else { break }

            let n = 1 << z
            let (firstColumn, columnCount) = box.columns(at: z)
            let (firstRow, rowCount) = box.rows(at: z)
            for column in 0..<columnCount {
                // Columns wrap: a route across the antimeridian runs off the
                // east edge of the grid and continues at column zero.
                let x = SlippyTileMath.wrap(firstColumn + column, to: n)
                for row in 0..<rowCount {
                    tiles.append(
                        Tile(z: z, x: x, y: firstRow + row)
                    )
                }
            }
            running += count
        }
        return tiles
    }
}
