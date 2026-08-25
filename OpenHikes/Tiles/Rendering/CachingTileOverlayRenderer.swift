//
//  CachingTileOverlayRenderer.swift
//  OpenHikes
//
//  Draws map tiles from the cache, falling back to clipped lower-zoom tiles
//  while higher-zoom tiles load. This avoids the blank/flickering tiles seen
//  with MKTileOverlayRenderer when zooming hard.
//
//  Adapted from stadiamaps/mapkit-caching-tile-overlay, modernized to use
//  async tile loading and a lock-protected in-flight set.
//

import MapKit
import os
import Synchronization

// Why the tile loads below go through a gate at all:
//
// `loadTileIfNeeded` spawns one unstructured `Task` per cache-missed tile, and
// nothing about the draw pass bounds how many of those there are. Normally
// that's a handful. But right after fitting the map to a freshly-imported
// route, MapKit's zoom-to-fit animation calls `draw(_:zoomScale:in:)` across
// many tiles and zoom levels in quick succession, and since a fresh route has
// nothing cached yet, every one of them is a miss. That can fire off dozens of
// Tasks together, each blocking a thread in Swift's small cooperative pool on
// synchronous filesystem work (slower still on the Simulator). The pool
// doesn't grow to absorb that — it backs up, and since MapKit's own
// tile-rendering dispatch competes for the same worker threads, the whole map
// can appear to freeze, including after switching providers (the new
// overlay's tile loads queue up behind the same jam).
//
// The gate is shared with the bulk downloader, and these loads take it at
// `.interactive` — see `TileLoadGate` for what that guarantees.

/// `@unchecked Sendable` for the same reason ``TileOverlay`` is: it is an
/// `MKOverlayRenderer` (which the MapKit SDK does not declare `Sendable`)
/// whose own mutable state — the in-flight set, the failure log and the
/// pending retry wake-up — lives behind `Mutex`es, and whose tile loads run
/// as unstructured tasks off the main thread. The one member that genuinely
/// requires the main thread, `setNeedsDisplay`, is called through an explicit
/// hop at every one of those sites.
///
/// The annotation stays `@unchecked` only because of the superclass: every
/// stored property below is `Sendable` on its own.
nonisolated final class CachingTileOverlayRenderer: MKOverlayRenderer, TileCacheObserver, @unchecked Sendable {
    private struct Fallback {
        let image: TileImage
        let sourceRect: CGRect
    }

    private static let logger = Logger(subsystem: "OpenHikes", category: "TileRenderer")

    /// How many zoom levels to walk up looking for a tile to crop for overzoom.
    private let maxFallbackDepth = 8

    /// Keys of tiles currently being fetched, to avoid duplicate requests.
    private let inFlight = Mutex(Set<String>())

    /// Tiles that failed to load (offline, 500, timeout, undecodable, 404),
    /// and when each may be asked for again. Skipping them is what stops a
    /// failed tile spinning a request/redraw loop; expiring the skip is what
    /// stops a transient server error leaving a permanent hole in the map.
    /// See ``TileFailureLog``.
    private let failures = Mutex(TileFailureLog())

    /// The pending "a backoff has elapsed, redraw" wake-up, and when it fires.
    /// At most one is scheduled at a time: a redraw retries every tile that
    /// has come due, so the earliest deadline covers all of them.
    private struct RetryWake {
        var task: Task<Void, Never>?
        var dueAt: ContinuousClock.Instant?
    }

    private let retryWake = Mutex(RetryWake())

    private let tileOverlay: TileOverlay

    /// The cache this renderer answers to — the overlay's, never the app's
    /// singleton. ``TileOverlay/cache`` is injectable precisely so a test can
    /// hand over one wired to a stub transport and its own directories, and a
    /// renderer that reached for `TileCache.shared` instead would register its
    /// reconnect listener on, and read `isOnline` from, a cache the overlay
    /// has nothing to do with.
    private var cache: TileCache { tileOverlay.cache }

    init(overlay: TileOverlay) {
        tileOverlay = overlay
        super.init(overlay: overlay)
        // Retry tiles once the network is back (delivered on the main queue).
        overlay.cache.addObserver(self)
    }

    deinit {
        tileOverlay.cache.removeObserver(self)
        retryWake.withLock { $0.task?.cancel() }
    }

    /// `TileCacheObserver` — network is back: forget past failures and redraw so
    /// the now-reachable tiles get requested again.
    ///
    /// Still a wholesale clear rather than a backoff reset, because this is
    /// the one event that invalidates every past failure at once: they were
    /// all recorded against a network that no longer applies.
    func tileCacheDidReconnect() {
        let clearedCount = failures.withLock { $0.removeAll() }
        cancelRetryWake()
        #if DEBUG
        if clearedCount > 0 {
            Self.logger.debug("Reconnected — clearing \(clearedCount, privacy: .public) failed tile(s) for retry")
        }
        #endif
        setNeedsDisplay()
    }

    // MARK: Retry scheduling

    /// Arranges a redraw for when the soonest-eligible failed tile comes due.
    ///
    /// Without this, a retry only happens when something else causes a draw
    /// pass — so a user who stops panning keeps staring at the hole. With it,
    /// the map heals itself while sitting still.
    ///
    /// This is the redraw-on-failure loop the renderer was originally written
    /// to avoid, made safe by being bounded: one wake-up at a time however
    /// many tiles failed, and each tile's own deadline grows 5 s → 15 s →
    /// 45 s → 2 min → 5 min, so a genuinely absent tile settles at one redraw
    /// every five minutes rather than one per draw pass.
    ///
    /// Called from the end of every draw pass as well as from a failure,
    /// because a wake-up clears itself when it fires and the pass it triggers
    /// need not record a new failure to re-arm it. A tile five failures deep
    /// waits five minutes; a tile that came due in the same pass and *loaded*
    /// removes itself from the log. Re-arming only on failure left the deep
    /// one with no timer behind it, healing only if the user panned or the
    /// network reconnected — which is the situation this exists to fix.
    private func scheduleRetryWake() {
        // Offline, `TileFailureLog` holds every failed tile indefinitely and
        // the reconnect notification is what releases them — so there is
        // nothing for a timer to make eligible.
        guard cache.isOnline,
              let due = failures.withLock({ $0.earliestRetry(after: .now) })
        else { return }

        retryWake.withLock { wake in
            // A wake-up already scheduled at or before this deadline covers it.
            if wake.task != nil, let pending = wake.dueAt, pending <= due { return }
            wake.task?.cancel()
            wake.dueAt = due
            wake.task = Task { [weak self] in
                try? await Task.sleep(until: due, clock: ContinuousClock())
                guard !Task.isCancelled, let self else { return }
                retryWake.withLock { $0.task = nil; $0.dueAt = nil }
                await MainActor.run { self.setNeedsDisplay() }
            }
        }
    }

    private func cancelRetryWake() {
        retryWake.withLock { wake in
            wake.task?.cancel()
            wake.task = nil
            wake.dueAt = nil
        }
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
                // request URL the tile server rejects, leaving that spot blank.
                // Normalize before it's used for caching, fallback, or fetching.
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
                    if let fallback = fallback(for: path, in: overlay) {
                        drawImage(
                            fallback.image,
                            in: drawRect,
                            context: context,
                            sourceRect: fallback.sourceRect
                        )
                    }
                    loadTileIfNeeded(for: path, in: tileRect, overlay: overlay)
                }
            }
        }

        // Every exit from `loadTileIfNeeded` above can leave a tile waiting on
        // a deadline with no wake-up behind it — a tile skipped for still
        // being inside its backoff, or one that loaded and cleared the failure
        // whose wake happened to be the timer everything else was riding on.
        // Re-arming here makes it one call per pass rather than one per tile,
        // and makes the invariant unconditional: after any draw, the soonest
        // surviving deadline has a timer on it.
        scheduleRetryWake()
    }

    // MARK: Loading

    private func loadTileIfNeeded(for path: MKTileOverlayPath, in tileRect: MKMapRect, overlay: TileOverlay) {
        // Beyond the source's max zoom no real tile exists, so fetch the deepest
        // real ancestor instead — the fallback step will crop it for overzoom.
        let fetchPath = path.z > overlay.maximumZ ? path.ancestor(atZoom: overlay.maximumZ) : path
        let key = fetchPath.cacheKey

        // Skip tiles we already know we can't get — until their backoff runs
        // out, or a reconnect clears them outright.
        let now = ContinuousClock.now
        let isOnline = cache.isOnline
        guard failures.withLock({ $0.mayAttempt(key, at: now, isOnline: isOnline) }) else { return }

        let isNew = inFlight.withLock { $0.insert(key).inserted }
        guard isNew else { return }

        // Deliberately *not* @MainActor: `cacheTile` does network I/O, disk
        // reads/writes, and (via AutoSaveTileStore) a file move into durable
        // storage — all synchronous once awaited. Keeping this Task unisolated
        // runs that work off the main thread instead of stalling it every
        // scroll/zoom.
        Task { [weak self] in
            await TileLoadGate.shared.acquire(.interactive)
            let loaded = await overlay.cacheTile(at: fetchPath)
            await TileLoadGate.shared.release(.interactive)
            guard let self else { return }
            inFlight.withLock { _ = $0.remove(key) }
            if loaded {
                // A tile that loads clears its own failure history, so a later
                // failure starts its backoff fresh rather than inheriting the
                // last run of bad luck.
                failures.withLock { $0.recordSuccess(key) }
                // Redraw only the tile that arrived. `setNeedsDisplay` must run
                // on the main thread (MapKit/UIKit requirement that isn't
                // statically enforced), hence the explicit hop here.
                await MainActor.run { self.setNeedsDisplay(tileRect) }
            } else {
                // Deliberately no redraw here: redrawing *on* failure is what
                // spun the request loop. The retry instead rides a wake-up
                // scheduled for when the backoff expires.
                let retryAt = failures.withLock { $0.recordFailure(key, at: .now) }
                scheduleRetryWake()
                #if DEBUG
                let seconds = ContinuousClock.now.duration(to: retryAt).components.seconds
                Self.logger.debug(
                    "Tile \(key, privacy: .public) failed — retry in \(seconds, privacy: .public)s (TileRequests log)"
                )
                #endif
            }
        }
    }

    /// Finds the nearest cached lower-zoom tile and identifies the relevant
    /// source region without allocating a cropped image.
    private func fallback(for path: MKTileOverlayPath, in overlay: TileOverlay) -> Fallback? {
        var ancestor = path
        for depth in 1...maxFallbackDepth where ancestor.z > 0 {
            ancestor = ancestor.parent
            if let image = overlay.cachedImage(at: ancestor) {
                return Fallback(
                    image: image,
                    sourceRect: cropRect(depth: depth, path: path, imageSize: image.size)
                )
            }
        }
        return nil
    }

    // MARK: Drawing

    private func drawImage(
        _ image: TileImage,
        in rect: CGRect,
        context: CGContext,
        sourceRect: CGRect? = nil
    ) {
        let imageRect: CGRect
        if let sourceRect {
            imageRect = scaledImageRect(
                imageSize: image.size,
                sourceRect: sourceRect,
                destinationRect: rect
            )
            context.saveGState()
            context.clip(to: rect)
        } else {
            imageRect = rect
        }

        #if canImport(UIKit)
        UIGraphicsPushContext(context)
        image.draw(in: imageRect)
        UIGraphicsPopContext()
        #elseif canImport(AppKit)
        let graphicsContext = NSGraphicsContext(cgContext: context, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext
        image.draw(in: imageRect)
        NSGraphicsContext.restoreGraphicsState()
        #endif

        if sourceRect != nil {
            context.restoreGState()
        }
    }

    /// Approximates a tile zoom level from a zoomScale (no public API for this).
    private func zoomLevel(for zoomScale: MKZoomScale, tileWidth: CGFloat) -> Int {
        let tilesAcrossWorld = MKMapSize.world.width / Double(tileWidth)
        return max(0, Int(log2(tilesAcrossWorld) + floor(log2(Double(zoomScale)) + 0.5)))
    }
}

/// The sub-rectangle of a `depth`-levels-up ancestor that corresponds to `path`.
nonisolated func cropRect(depth: Int, path: MKTileOverlayPath, imageSize: CGSize) -> CGRect {
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

/// Positions the full ancestor image so `sourceRect` exactly fills the
/// destination; the renderer clips to `destinationRect` before drawing it.
nonisolated func scaledImageRect(
    imageSize: CGSize,
    sourceRect: CGRect,
    destinationRect: CGRect
) -> CGRect {
    let scaleX = destinationRect.width / sourceRect.width
    let scaleY = destinationRect.height / sourceRect.height
    return CGRect(
        x: destinationRect.minX - sourceRect.minX * scaleX,
        y: destinationRect.minY - sourceRect.minY * scaleY,
        width: imageSize.width * scaleX,
        height: imageSize.height * scaleY
    )
}
