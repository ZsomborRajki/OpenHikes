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

    /// Tiles currently being fetched, each holding the screen rects waiting on
    /// it, so a duplicate request is avoided without leaving the tiles that
    /// were folded into it with nothing to redraw them.
    ///
    /// Overzoomed tiles share one ancestor: sixteen screen tiles at z21 all
    /// want the same z19 bytes. Only the first asks, and if the arrival
    /// invalidated only the asker's rect, the other fifteen would stay blank
    /// until an unrelated pan or zoom happened to redraw them.
    private let inFlight = Mutex([String: [MKMapRect]]())

    /// Tiles whose requests failed (500, timeout, undecodable, 404), and when
    /// each may be asked for again. Skipping them is what stops a failed tile
    /// spinning a request/redraw loop; expiring the skip is what stops a
    /// transient server error leaving a permanent hole in the map. See
    /// ``TileFailureLog``.
    ///
    /// A load ``TileNetworkPolicy`` refused never enters this log — no server
    /// was asked, so there is nothing to back off from. Those go in
    /// ``suppressed`` instead.
    private let failures = Mutex(TileFailureLog())

    /// Tiles the network policy declined to request, and that are not in the
    /// cache either. Skipped until the policy changes its mind.
    ///
    /// Without this the offline map is undamped: `draw` misses on every
    /// uncached tile every pass, and each miss spends an unstructured `Task`,
    /// two ``TileLoadGate`` hops and a failed disk stat to be told the same
    /// "no" again — the per-tile-per-pass cost the failure log exists to
    /// avoid, and it lands hardest on the case this app is built for, panning
    /// the edge of a downloaded region with no signal, where these no-ops
    /// queue through the gate ahead of the cached neighbours' real loads.
    ///
    /// Held with no expiry, exactly as ``TileFailureLog/mayAttempt(_:at:isOnline:)``
    /// holds failures offline: the policy transition is the only thing that
    /// can make one of these loadable, and it always arrives as a path update
    /// — a tile cannot quietly appear on disk in the meantime, because a
    /// policy blocking the map blocks the bulk downloader first.
    private let suppressed = Mutex(Set<String>())

    /// The point past which remembering suppressed tiles costs more than the
    /// re-asking it saves. Dropping the lot is safe — it buys one extra pass
    /// of misses, not a wrong tile — so this needs no eviction order, unlike
    /// ``TileRetryPolicy/maximumTrackedFailures``, whose entries carry
    /// deadlines that differ.
    private static let maximumSuppressedTiles = 1024

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
    /// network-policy listener on, and read `isOnline` from, a cache the
    /// overlay has nothing to do with.
    private var cache: TileCache { tileOverlay.cache }

    init(overlay: TileOverlay) {
        tileOverlay = overlay
        super.init(overlay: overlay)
        // Retry tiles once interactive fetching is allowed (on the main queue).
        overlay.cache.addObserver(self)
    }

    deinit {
        tileOverlay.cache.removeObserver(self)
        retryWake.withLock { $0.task?.cancel() }
    }

    /// `TileCacheObserver` — network policy allows interactive requests again:
    /// forget past failures and redraw so the tiles get requested immediately.
    ///
    /// Still a wholesale clear rather than a backoff reset, because this is
    /// the one event that invalidates every past failure at once: they were
    /// all recorded against a network that no longer applies.
    func tileCacheDidUnblockInteractiveFetches() {
        let clearedCount = failures.withLock { $0.removeAll() }
        suppressed.withLock { $0.removeAll() }
        cancelRetryWake()
        #if DEBUG
        if clearedCount > 0 {
            Self.logger.debug(
                "Interactive fetching restored — clearing \(clearedCount, privacy: .public) failed tile(s)"
            )
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
        let zoom = Self.zoomLevel(for: zoomScale, tileWidth: overlay.tileSize.width)

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
                    let fallback = fallback(for: path, in: overlay)
                    if let fallback {
                        drawImage(
                            fallback.image,
                            in: drawRect,
                            context: context,
                            sourceRect: fallback.sourceRect
                        )
                    }
                    loadTileIfNeeded(
                        for: path,
                        in: tileRect,
                        overlay: overlay,
                        drewSomething: fallback != nil
                    )
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

    /// Which tile to actually fetch for a path the draw pass missed on, or
    /// `nil` when asking would achieve nothing.
    ///
    /// Beyond the source's maximum zoom no real tile exists, so the bytes come
    /// from the deepest real ancestor and the fallback step crops them. But
    /// they are also *filed* under that ancestor's key, while `draw` looks up
    /// the screen path — so above `maximumZ` the two keys can never agree, the
    /// lookup misses on every pass, and this runs unconditionally however warm
    /// the cache is.
    ///
    /// Answering with the ancestor anyway is what closed the loop: the load
    /// finds it in the memory tier, returns `true`, and the caller redraws —
    /// which misses again. That is the request/redraw cycle the failure branch
    /// below is written to avoid, reached through the success branch instead,
    /// and it spins one task, two gate hops and a full main-thread redraw per
    /// visible tile for as long as the map stays overzoomed, on a device
    /// nobody is touching. `nil` says the ancestor is already in memory, so
    /// there is nothing to fetch and nothing to invalidate.
    static func fetchPath(
        drawing path: MKTileOverlayPath,
        maximumZ: Int,
        isCached: (MKTileOverlayPath) -> Bool
    ) -> MKTileOverlayPath? {
        guard path.z > maximumZ else { return path }
        let ancestor = path.ancestor(atZoom: maximumZ)
        return isCached(ancestor) ? nil : ancestor
    }

    /// Whether this pass should ask for `key` at all.
    ///
    /// Two reasons not to, and they are not the same reason. A tile whose
    /// request failed waits out a backoff — until it expires, or until the
    /// policy transition clears the log outright. A tile the policy refused
    /// was never asked for, so it has no backoff to wait out and only that
    /// transition can release it.
    private func mayAsk(for key: String) -> Bool {
        let isOnline = cache.isOnline
        guard failures.withLock({ $0.mayAttempt(key, at: .now, isOnline: isOnline) }) else { return false }
        return !suppressed.withLock { $0.contains(key) }
    }

    private func loadTileIfNeeded(
        for path: MKTileOverlayPath,
        in tileRect: MKMapRect,
        overlay: TileOverlay,
        drewSomething: Bool
    ) {
        guard let fetchPath = Self.fetchPath(
            drawing: path,
            maximumZ: overlay.maximumZ,
            isCached: { overlay.cachedImage(at: $0) != nil }
        ) else {
            // The ancestor is in memory, so there is nothing to fetch — but
            // this pass may still have drawn nothing from it. Several
            // overzoomed screen tiles share one ancestor, and a sibling's load
            // can land between this pass's fallback lookup and this one,
            // leaving a blank tile with no invalidation behind it.
            //
            // Re-asking before invalidating is what keeps that from becoming
            // the redraw loop this guard exists to prevent: the redraw is
            // issued only when the fallback can now find something, and once
            // it can, the next pass draws it and reports `drewSomething`.
            if !drewSomething, fallback(for: path, in: overlay) != nil {
                Task { @MainActor [weak self] in self?.setNeedsDisplay(tileRect) }
            }
            return
        }

        let key = fetchPath.cacheKey

        guard mayAsk(for: key) else { return }

        let isNew = inFlight.withLock { pending -> Bool in
            guard pending[key] == nil else {
                // A stalled fetch can be drawn over more than once. Redrawing
                // a rect already waiting achieves nothing, and skipping it is
                // what keeps this list the size of the screen rather than the
                // size of however long the network took.
                if pending[key]?.contains(where: { MKMapRectEqualToRect($0, tileRect) }) == false {
                    pending[key]?.append(tileRect)
                }
                return false
            }
            pending[key] = [tileRect]
            return true
        }
        guard isNew else { return }

        // Deliberately *not* @MainActor: `cacheTile` does network I/O, disk
        // reads/writes, and (via AutoSaveTileStore) a file move into durable
        // storage — all synchronous once awaited. Keeping this Task unisolated
        // runs that work off the main thread instead of stalling it every
        // scroll/zoom.
        Task { [weak self] in
            await TileLoadGate.shared.acquire(.interactive)
            let disposition = await overlay.cacheTile(at: fetchPath)
            await TileLoadGate.shared.release(.interactive)
            guard let self else { return }
            let waiting = inFlight.withLock { $0.removeValue(forKey: key) ?? [tileRect] }
            switch disposition {
            case .loaded:
                // A tile that loads clears its own failure history, so a later
                // failure starts its backoff fresh rather than inheriting the
                // last run of bad luck.
                failures.withLock { $0.recordSuccess(key) }
                // Redraw every rect these bytes cover — the asker, plus any
                // overzoomed sibling whose request was folded into it.
                // `setNeedsDisplay` must run on the main thread (a MapKit/UIKit
                // requirement that isn't statically enforced), hence the hop.
                await MainActor.run {
                    for rect in waiting { self.setNeedsDisplay(rect) }
                }
            case .failed:
                // Deliberately no redraw here: redrawing *on* failure is what
                // spun the request loop. The retry instead rides a wake-up
                // scheduled for when the backoff expires.
                //
                // A server that answered 429 or 503 with `Retry-After` named
                // its own deadline, and that is fed in as a floor rather than
                // as a second mechanism: the tile waits for whichever is
                // longer. Read before the lock, since it takes the cache's.
                let serverDeadline = overlay.retryDeadline(at: fetchPath)
                let retryAt = failures.withLock { log in
                    log.recordFailure(key, at: .now, notBefore: serverDeadline)
                }
                scheduleRetryWake()
                #if DEBUG
                let seconds = ContinuousClock.now.duration(to: retryAt).components.seconds
                Self.logger.debug(
                    "Tile \(key, privacy: .public) failed — retry in \(seconds, privacy: .public)s (TileRequests log)"
                )
                #endif
            case .suppressed:
                // No request was made, so there is no server failure to back
                // off — just a tile not worth asking about again until the
                // policy changes. The cache observer clears these and redraws
                // when it does.
                suppressed.withLock { keys in
                    if keys.count >= Self.maximumSuppressedTiles { keys.removeAll() }
                    keys.insert(key)
                }
            }
        }
    }

    #if DEBUG
    /// Test seam: the skip decision a draw pass makes and discards. Exposed
    /// rather than restated, so a test that loses the suppression check fails
    /// instead of agreeing with a copy of it.
    func mayAskForTile(at path: MKTileOverlayPath) -> Bool {
        mayAsk(for: path.cacheKey)
    }

    /// Test seam: how many tiles are being skipped, and for which of the two
    /// reasons — the distinction this renderer exists to keep straight.
    var skipCounts: (failed: Int, suppressed: Int) {
        (failures.withLock { $0.count }, suppressed.withLock { $0.count })
    }

    /// Test seam: one tile's worth of what `draw(_:zoomScale:in:)` does on a
    /// miss. Reaching that branch through the real pass costs a bitmap
    /// context and a screenful of grid arithmetic for the one call underneath.
    func loadTileForTesting(at path: MKTileOverlayPath) {
        loadTileIfNeeded(
            for: path,
            in: tileOverlay.boundingMapRect,
            overlay: tileOverlay,
            drewSomething: false
        )
    }
    #endif

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

    /// The deepest level ``zoomLevel(for:tileWidth:)`` will report.
    ///
    /// Eight levels past the deepest `maximumZ` any provider here declares, so
    /// it cannot shorten a real map, and far enough below the width of an
    /// `Int` that `1 << zoom` in `draw` stays a positive tile count. That
    /// second part is the one that matters: at 64 the shift yields zero, and
    /// `SlippyTileMath.wrap(_:to:)` divides by it.
    static let maximumZoomLevel = 30

    /// Approximates a tile zoom level from a zoomScale (no public API for this).
    ///
    /// The level is `log2` of how many tiles span the world at this scale,
    /// rounded half *up* — so the scale exactly halfway between two levels
    /// draws the deeper one, and a level covers scales in
    /// `[2^(k-0.5), 2^(k+0.5))`. Doubling the scale adds exactly one level;
    /// doubling the tile width takes one away, which is the only way a
    /// display scale enters — this reads no `contentScaleFactor`, because a
    /// retina screen is served the same level as an `@2x` asset rather than a
    /// deeper level.
    ///
    /// `static` and not `private` for the same reason ``fetchPath`` is: it
    /// reads nothing but its arguments, and a wrong answer here is invisible —
    /// the map is uniformly blurry or fetches four times the tiles it needs,
    /// and nothing throws, logs or crashes.
    static func zoomLevel(for zoomScale: MKZoomScale, tileWidth: CGFloat) -> Int {
        let tilesAcrossWorld = MKMapSize.world.width / Double(tileWidth)
        let level = log2(tilesAcrossWorld) + floor(log2(Double(zoomScale)) + 0.5)
        // `Int(_:)` traps on a non-finite `Double`, and every degenerate input
        // reaches it as one: a zero, negative or NaN scale (or tile width)
        // makes `log2` return -infinity or NaN, and an infinite scale or a
        // zero width makes it +infinity. MapKit passes neither today, so this
        // is a guard against a future caller rather than a live crash — but
        // the trap it replaces is unconditional, and answering it with the
        // whole world (or the deepest level) is the only interpretation that
        // still draws something.
        guard level.isFinite else { return level > 0 ? Self.maximumZoomLevel : 0 }
        return min(Self.maximumZoomLevel, max(0, Int(level)))
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
