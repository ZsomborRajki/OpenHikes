//
//  CachingTileOverlayRenderer.swift
//  OpenTrails
//
//  Draws OSM tiles from the cache, falling back to cropped lower-zoom tiles
//  while higher-zoom tiles load. This avoids the blank/flickering tiles seen
//  with MKTileOverlayRenderer when zooming hard.
//
//  Adapted from stadiamaps/mapkit-caching-tile-overlay, modernized to use
//  async tile loading and a lock-protected in-flight set.
//

import MapKit
import os

/// Bounds how many tile-load pipelines (network fetch, disk I/O, and — via
/// ``AutoSaveTileStore`` — HEIC encoding) run their blocking work at once.
///
/// `loadTileIfNeeded` spawns one unstructured `Task` per cache-missed tile,
/// with nothing limiting how many run together. Normally that's a handful.
/// But right after fitting the map to a freshly-imported route, MapKit's
/// zoom-to-fit animation calls `draw(_:zoomScale:in:)` across many tiles and
/// zoom levels in quick succession, and since a fresh route has nothing
/// cached yet, every one of them is a miss. That can fire off dozens of Tasks
/// together, each blocking a thread in Swift's small cooperative pool on
/// synchronous disk reads/writes and HEIC encoding (slower still on the
/// Simulator). The pool doesn't grow to absorb that — it backs up, and since
/// MapKit's own tile-rendering dispatch competes for the same worker threads,
/// the whole map can appear to freeze, including after switching providers
/// (the new overlay's tile loads queue up behind the same jam).
///
/// Mirrors ``OfflineTileDownloader``'s `maxConcurrent`, which already caps
/// its own bulk-download pipeline the same way.
private actor TileLoadGate {
    static let shared = TileLoadGate()
    private let maxConcurrent = 4
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if active < maxConcurrent {
            active += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// Hands the freed slot straight to the next waiter when there is one, so
    /// `active` never dips below what's really in flight between the two.
    func release() {
        guard !waiters.isEmpty else {
            active -= 1
            return
        }
        waiters.removeFirst().resume()
    }
}

nonisolated final class CachingTileOverlayRenderer: MKOverlayRenderer, TileCacheObserver {
    private static let logger = Logger(subsystem: "OpenTrails", category: "TileRenderer")

    /// How many zoom levels to walk up looking for a tile to crop for overzoom.
    private let maxFallbackDepth = 8

    /// Keys of tiles currently being fetched, to avoid duplicate requests.
    private let inFlight = OSAllocatedUnfairLock(initialState: Set<String>())

    /// Keys of tiles that failed to load (offline, 404, …). Skipped until we
    /// reconnect, so a failed tile never triggers an endless request/redraw loop.
    private let failed = OSAllocatedUnfairLock(initialState: Set<String>())

    private var tileOverlay: OSMTileOverlay { overlay as! OSMTileOverlay }

    init(overlay: OSMTileOverlay) {
        super.init(overlay: overlay)
        // Retry tiles once the network is back (delivered on the main queue).
        TileCache.shared.addObserver(self)
    }

    deinit {
        TileCache.shared.removeObserver(self)
    }

    /// `TileCacheObserver` — network is back: forget past failures and redraw so
    /// the now-reachable tiles get requested again.
    func tileCacheDidReconnect() {
        let clearedCount = failed.withLock { count -> Int in
            let n = count.count
            count.removeAll()
            return n
        }
        #if DEBUG
        if clearedCount > 0 {
            Self.logger.debug("Reconnected — clearing \(clearedCount, privacy: .public) failed tile(s) for retry")
        }
        #endif
        setNeedsDisplay()
    }

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        let overlay = tileOverlay
        let overlayRect = overlay.boundingMapRect
        let tileMapSize = Double(overlay.tileSize.width) / Double(zoomScale)
        let zoom = zoomLevel(for: zoomScale, tileWidth: overlay.tileSize.width)

        let firstCol = Int(floor((mapRect.minX - overlayRect.origin.x) / tileMapSize))
        let lastCol = Int(floor((mapRect.maxX - overlayRect.origin.x) / tileMapSize))
        let firstRow = Int(floor((mapRect.minY - overlayRect.origin.y) / tileMapSize))
        let lastRow = Int(floor((mapRect.maxY - overlayRect.origin.y) / tileMapSize))
        // Column/row count at this zoom — used to keep tile indices in range.
        let tileCount = 1 << zoom

        for x in firstCol...lastCol {
            for y in firstRow...lastRow {
                let tileRect = MKMapRect(
                    x: Double(x) * tileMapSize,
                    y: Double(y) * tileMapSize,
                    width: tileMapSize,
                    height: tileMapSize
                )
                // MapKit can hand out columns/rows outside the valid tile grid
                // while panning/scrolling continuously around the world (or
                // near the poles) — an unnormalized path produces an invalid
                // request URL that the tile server 400s, permanently blanking
                // that spot until reconnect. Normalize before it's used for
                // caching, fallback, or fetching.
                let path = MKTileOverlayPath(
                    x: SlippyTileMath.wrap(x, to: tileCount),
                    y: SlippyTileMath.clamp(y, to: tileCount),
                    z: zoom,
                    contentScaleFactor: contentScaleFactor
                )
                let drawRect = rect(for: tileRect)

                if let image = overlay.cachedImage(at: path) {
                    drawImage(image, in: drawRect, context: context)
                } else {
                    if let fallback = fallbackImage(for: path, in: overlay) {
                        drawImage(fallback, in: drawRect, context: context)
                    }
                    loadTileIfNeeded(for: path, in: tileRect, overlay: overlay)
                }
            }
        }
    }

    // MARK: - Loading

    private func loadTileIfNeeded(for path: MKTileOverlayPath, in tileRect: MKMapRect, overlay: OSMTileOverlay) {
        // Beyond the source's max zoom no real tile exists, so fetch the deepest
        // real ancestor instead — the fallback step will crop it for overzoom.
        let fetchPath = path.z > overlay.maximumZ ? path.ancestor(atZoom: overlay.maximumZ) : path
        let key = fetchPath.cacheKey

        // Skip tiles we already know we can't get, until a reconnect clears them.
        guard !failed.withLock({ $0.contains(key) }) else { return }

        let isNew = inFlight.withLock { $0.insert(key).inserted }
        guard isNew else { return }

        // Deliberately *not* @MainActor: `cacheTile` does network I/O, disk
        // reads/writes, and (via AutoSaveTileStore) HEIC encoding — all
        // synchronous once awaited. Keeping this Task unisolated runs that
        // work off the main thread instead of stalling it every scroll/zoom.
        Task { [weak self] in
            await TileLoadGate.shared.acquire()
            let loaded = await overlay.cacheTile(at: fetchPath)
            await TileLoadGate.shared.release()
            guard let self else { return }
            self.inFlight.withLock { _ = $0.remove(key) }
            if loaded {
                // Only redraw when there's actually a new tile to show — redrawing
                // on failure is what spun the request loop. `setNeedsDisplay` must
                // run on the main thread (MapKit/UIKit requirement that isn't
                // statically enforced), hence the explicit hop here.
                await MainActor.run { self.setNeedsDisplay(tileRect) }
            } else {
                self.failed.withLock { _ = $0.insert(key) }
                #if DEBUG
                Self.logger.debug("Tile \(key, privacy: .public) marked failed — renders blank until reconnect (see TileRequests log for the reason)")
                #endif
            }
        }
    }

    /// Finds the nearest cached lower-zoom tile and crops the relevant quadrant.
    private func fallbackImage(for path: MKTileOverlayPath, in overlay: OSMTileOverlay) -> TileImage? {
        var ancestor = path
        for depth in 1...maxFallbackDepth where ancestor.z > 0 {
            ancestor = ancestor.parent
            if let image = overlay.cachedImage(at: ancestor) {
                return image.cropped(to: cropRect(depth: depth, path: path, imageSize: image.size))
            }
        }
        return nil
    }

    // MARK: - Drawing

    private func drawImage(_ image: TileImage, in rect: CGRect, context: CGContext) {
        #if canImport(UIKit)
        UIGraphicsPushContext(context)
        image.draw(in: rect)
        UIGraphicsPopContext()
        #elseif canImport(AppKit)
        let graphicsContext = NSGraphicsContext(cgContext: context, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext
        image.draw(in: rect)
        NSGraphicsContext.restoreGraphicsState()
        #endif
    }

    /// Approximates a tile zoom level from a zoomScale (no public API for this).
    private func zoomLevel(for zoomScale: MKZoomScale, tileWidth: CGFloat) -> Int {
        let tilesAcrossWorld = MKMapSize.world.width / Double(tileWidth)
        return max(0, Int(log2(tilesAcrossWorld) + floor(log2(Double(zoomScale)) + 0.5)))
    }
}

/// The sub-rectangle of a `depth`-levels-up ancestor that corresponds to `path`.
private nonisolated func cropRect(depth: Int, path: MKTileOverlayPath, imageSize: CGSize) -> CGRect {
    let factor = 1 << depth
    let subWidth = imageSize.width / CGFloat(factor)
    let subHeight = imageSize.height / CGFloat(factor)
    return CGRect(
        x: CGFloat(path.x % factor) * subWidth,
        y: CGFloat(path.y % factor) * subHeight,
        width: subWidth,
        height: subHeight
    )
}

nonisolated extension TileImage {
    /// Returns a new image cropped to `rect`, expressed in the image's point space.
    func cropped(to rect: CGRect) -> TileImage? {
        #if canImport(UIKit)
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = scale
        return UIGraphicsImageRenderer(size: rect.size, format: format).image { _ in
            draw(at: CGPoint(x: -rect.origin.x, y: -rect.origin.y))
        }
        #elseif canImport(AppKit)
        return NSImage(size: rect.size, flipped: true) { _ in
            self.draw(
                in: NSRect(x: -rect.origin.x, y: -rect.origin.y, width: self.size.width, height: self.size.height),
                from: NSRect(origin: .zero, size: self.size),
                operation: .copy,
                fraction: 1.0,
                respectFlipped: true,
                hints: nil
            )
            return true
        }
        #endif
    }
}
