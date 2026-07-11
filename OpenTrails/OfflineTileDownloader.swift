//
//  OfflineTileDownloader.swift
//  OpenTrails
//
//  Pre-fetches the map tiles covering a route's bounding box across a range of
//  zoom levels and primes `TileCache` with them, so the route can be viewed
//  offline later. Tiles are stored under the exact keys the map renderer looks
//  up (`providerID/z/x/y@scale`), so a warmed cache is served transparently.
//

import Foundation
import CoreLocation

@MainActor
@Observable
final class OfflineTileDownloader {
    enum Phase: Equatable { case idle, downloading, finished, failed(String) }

    private(set) var phase: Phase = .idle
    private(set) var completed = 0
    private(set) var total = 0

    /// 0…1 fraction of tiles fetched, for a progress indicator.
    var progress: Double { total == 0 ? 0 : min(1, Double(completed) / Double(total)) }

    var isFailed: Bool { if case .failed = phase { return true } else { return false } }

    private var task: Task<Void, Never>?

    /// Selectable deepest-zoom levels for the offline setting, and the default.
    static let zoomRange = 13...18
    static let defaultMaxZoom = 16

    /// The shallowest zoom to save (whole-route overview).
    static let minZoom = 10
    /// Soft cap on tiles — deeper zoom levels are dropped once exceeded, so a huge
    /// route doesn't try to fetch hundreds of thousands of tiles.
    static let tileBudget = 4_000
    private let maxConcurrent = 5

    /// Begins downloading the tiles covering `route` from `source`, saving detail
    /// down to `maxZoom` (clamped to the provider's real max). `scale` must be the
    /// display scale so cache keys match what the renderer requests on-device.
    func start(route: [CLLocationCoordinate2D], source: ActiveTileSource, maxZoom: Int, scale: CGFloat) {
        guard phase != .downloading else { return }
        guard route.count > 1 else { phase = .failed("No route to save."); return }
        guard TileCache.shared.isOnline else { phase = .failed("You're offline — connect to save tiles."); return }

        let tiles = Self.tiles(
            covering: route,
            minZoom: Self.minZoom,
            maxZoom: min(max(maxZoom, Self.minZoom), source.maximumZ),
            budget: Self.tileBudget
        )
        guard !tiles.isEmpty else { phase = .failed("Nothing to save."); return }

        completed = 0
        total = tiles.count
        phase = .downloading
        task = Task { [weak self] in
            await self?.run(tiles: tiles, source: source, scale: scale)
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        phase = .idle
        completed = 0
        total = 0
    }

    /// Returns to idle after a finished/failed download (e.g. its tiles were deleted).
    func reset() {
        guard phase != .downloading else { return }
        phase = .idle
        completed = 0
        total = 0
    }

    private func run(tiles: [Tile], source: ActiveTileSource, scale: CGFloat) async {
        let cache = TileCache.shared
        var index = 0

        await withTaskGroup(of: Void.self) { group in
            var active = 0

            func addNext() {
                guard index < tiles.count else { return }
                let tile = tiles[index]
                index += 1
                active += 1
                group.addTask {
                    guard let url = tile.url(from: source.urlTemplate) else { return }
                    await cache.loadTile(forKey: tile.cacheKey(providerID: source.providerID, scale: scale), url: url)
                }
            }

            for _ in 0..<min(maxConcurrent, tiles.count) { addNext() }

            while active > 0 {
                await group.next()
                active -= 1
                completed += 1
                if Task.isCancelled { break }
                addNext()
            }
        }

        phase = Task.isCancelled ? .idle : .finished
    }

    // MARK: - Stored-tile bookkeeping

    /// The cache keys for every tile a download of `route` would produce for the
    /// given provider/scale/depth — so stored tiles can be measured and removed
    /// after the fact. Deterministic: recomputing yields exactly the saved set.
    static func tileKeys(for route: [CLLocationCoordinate2D], providerID: String, providerMaxZoom: Int, maxZoom: Int, scale: CGFloat) -> [String] {
        let clamped = min(max(maxZoom, minZoom), providerMaxZoom)
        return tiles(covering: route, minZoom: minZoom, maxZoom: clamped, budget: tileBudget)
            .map { $0.cacheKey(providerID: providerID, scale: scale) }
    }

    /// The union of cache keys across all of a hike's recorded downloads.
    static func storedTileKeys(for hike: Hike) -> [String] {
        guard !hike.offlineDownloads.isEmpty else { return [] }
        let route = hike.coordinates
        var keys = Set<String>()
        for record in hike.offlineDownloads {
            let provider = TileProvider.provider(id: record.providerID)
            keys.formUnion(tileKeys(
                for: route,
                providerID: record.providerID,
                providerMaxZoom: provider.maximumZ,
                maxZoom: record.maxZoom,
                scale: CGFloat(record.scale)
            ))
        }
        return Array(keys)
    }

    // MARK: - Tile enumeration

    struct Tile {
        let z: Int
        let x: Int
        let y: Int

        nonisolated func url(from template: String) -> URL? {
            let filled = template
                .replacingOccurrences(of: "{z}", with: String(z))
                .replacingOccurrences(of: "{x}", with: String(x))
                .replacingOccurrences(of: "{y}", with: String(y))
            return URL(string: filled)
        }

        /// Must mirror `OSMTileOverlay.cacheKey(for:)` exactly so warmed tiles are found.
        nonisolated func cacheKey(providerID: String, scale: CGFloat) -> String {
            "\(providerID)/\(z)/\(x)/\(y)@\(scale)"
        }
    }

    /// Enumerates the tiles covering the route's bounding box from `minZoom` up,
    /// stopping before a zoom level that would blow the tile budget.
    private static func tiles(covering route: [CLLocationCoordinate2D], minZoom: Int, maxZoom: Int, budget: Int) -> [Tile] {
        guard maxZoom >= minZoom else { return [] }

        var minLat = 90.0, maxLat = -90.0, minLon = 180.0, maxLon = -180.0
        for c in route {
            minLat = min(minLat, c.latitude); maxLat = max(maxLat, c.latitude)
            minLon = min(minLon, c.longitude); maxLon = max(maxLon, c.longitude)
        }

        var tiles: [Tile] = []
        var running = 0
        for z in minZoom...maxZoom {
            let n = 1 << z
            let xMin = clamp(tileX(minLon, z: z), to: n)
            let xMax = clamp(tileX(maxLon, z: z), to: n)
            let yMin = clamp(tileY(maxLat, z: z), to: n) // north edge → smaller y
            let yMax = clamp(tileY(minLat, z: z), to: n) // south edge → larger y
            let count = (xMax - xMin + 1) * (yMax - yMin + 1)
            if running + count > budget && !tiles.isEmpty { break }
            for x in xMin...xMax {
                for y in yMin...yMax {
                    tiles.append(Tile(z: z, x: x, y: y))
                }
            }
            running += count
        }
        return tiles
    }

    private static func clamp(_ value: Int, to n: Int) -> Int { min(max(value, 0), n - 1) }

    /// Slippy-map tile column for a longitude at zoom `z`.
    private static func tileX(_ lon: Double, z: Int) -> Int {
        Int(floor((lon + 180) / 360 * Double(1 << z)))
    }

    /// Slippy-map tile row for a latitude at zoom `z`.
    private static func tileY(_ lat: Double, z: Int) -> Int {
        let r = lat * .pi / 180
        return Int(floor((1 - log(tan(r) + 1 / cos(r)) / .pi) / 2 * Double(1 << z)))
    }
}
