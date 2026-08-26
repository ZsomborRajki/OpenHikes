//
//  OfflineTileDownloader+Planning.swift
//  OpenHikes
//

import CoreLocation
import Foundation

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

        func cacheKey(providerID: String, scale: CGFloat) -> String {
            TileCacheKey.namespaced(
                providerID: providerID,
                z: z,
                x: x,
                y: y,
                scale: scale
            )
        }
    }

    /// `@concurrent` so a tap that starts a download does its O(tileBudget)
    /// planning on the concurrent executor while staying in the download
    /// task — cancelling that task stops planning immediately.
    @concurrent
    static func plannedTiles(
        for route: [RouteCoordinate],
        maxZoom: Int,
        providerID: String
    ) async throws(CancellationError) -> [Tile] {
        assertOffMainThread(
            "Offline-download planning must stay off the main thread"
        )
        // The one thing that runs before a download commits to any network
        // traffic, so a trace can tell "the tap did nothing for two seconds"
        // apart from "the tile server was slow".
        let interval = RenderSignpost.beginInterval("OfflineDownloadPlan")
        defer { RenderSignpost.endInterval("OfflineDownloadPlan", interval) }
        var coordinates: [CLLocationCoordinate2D] = []
        coordinates.reserveCapacity(route.count)
        for (index, point) in route.enumerated() {
            if index.isMultiple(of: 255), Task.isCancelled { throw CancellationError() }
            coordinates.append(point.clCoordinate)
        }
        let result = tiles(
            covering: coordinates,
            minZoom: minZoom,
            maxZoom: maxZoom,
            budget: tileBudget(forProviderID: providerID)
        )
        guard !Task.isCancelled else { throw CancellationError() }
        RenderSignpost.mark(
            "OfflineDownloadPlanned",
            "route=\(route.count) maxZoom=\(maxZoom) tiles=\(result.count)"
        )
        return result
    }

    /// The cache keys every tile a download of `route` would produce for the
    /// given provider, scale, and depth — so stored tiles can be measured and
    /// removed after the fact. Deterministic: recomputing yields exactly the
    /// saved set.
    static func tileKeys(
        for route: [CLLocationCoordinate2D],
        providerID: String,
        providerMaxZoom: Int,
        maxZoom: Int,
        scale: CGFloat
    ) -> [String] {
        let clamped = min(max(maxZoom, minZoom), providerMaxZoom)
        return tiles(
            covering: route,
            minZoom: minZoom,
            maxZoom: clamped,
            budget: tileBudget(forProviderID: providerID)
        ).map { tile in
            tile.cacheKey(providerID: providerID, scale: scale)
        }
    }

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
        let interval = RenderSignpost.beginInterval("OfflineKeyRecompute")
        defer { RenderSignpost.endInterval("OfflineKeyRecompute", interval) }
        var keys = Set<String>()
        for record in offlineDownloads {
            // Every record, not every nth: each one re-walks the whole route
            // to build its bounding box, so a route-sized unit of work sits
            // between consecutive checks even when there are only two records.
            guard !Task.isCancelled else { throw CancellationError() }
            if !record.savedTileKeys.isEmpty {
                keys.formUnion(record.savedTileKeys)
                continue
            }
            let provider = TileProvider.provider(id: record.providerID)
            keys.formUnion(
                tileKeys(
                    for: route,
                    providerID: record.providerID,
                    providerMaxZoom: provider.maximumZ,
                    maxZoom: record.maxZoom,
                    scale: CGFloat(record.scale)
                )
            )
        }
        RenderSignpost.mark(
            "OfflineKeysRecomputed",
            "records=\(offlineDownloads.count) keys=\(keys.count)"
        )
        return Array(keys)
    }

    /// Enumerates the tiles covering the route's bounding box from the overview
    /// zoom up, stopping before a zoom level that would exceed the tile budget.
    private static func tiles(
        covering route: [CLLocationCoordinate2D],
        minZoom: Int,
        maxZoom: Int,
        budget: Int
    ) -> [Tile] {
        guard maxZoom >= minZoom,
              let box = TileBoundingBox(route: route) else { return [] }

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
