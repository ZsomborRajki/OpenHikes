//
//  VectorTileClient.swift
//  OpenHikes
//
//  Turns a cache key into a drawn tile, for the providers that have a
//  ``VectorTileSource``: the archive tile off the OpenHikes tile server, drawn
//  by ``VectorTileRasterizer``, as PNG bytes the cache files like any tile.
//
//  ``Drawing/fallBack`` is the fallback, never a blank tile. ``TileCache``
//  goes on to the provider's raster template, tile.openstreetmap.org for
//  OpenStreetMap, so a hiker sees the old map where the new one cannot be
//  drawn. That covers three cases:
//  - the server is down or failing: a transport error, a timeout, a 5xx or
//    a 429. The archive that failed is then passed over for
//    ``failurePause``, or for as long as its `Retry-After` asks where
//    ``RetryAfterHeader`` honors one, so a screenful of tiles does not each
//    wait on it before falling back. That archive alone: the extras failing
//    leave the basemap asked.
//  - the archive has no tile there.
//  - the tile could not be read or drawn. Bytes that could not be read are
//    not kept, so the next tile that needs them asks for them again.
//
//  A failure of the device's own connection is not the server's: no route,
//  cellular data off for the app. It pauses nothing and falls back to
//  nothing (``Drawing/offline``), because the raster template would fail the
//  same way, and a raster tile that came back would be filed for a week
//  among the drawn ones. A connection lost mid-request is either's: the
//  server may have dropped it, or the phone moved between networks. It is
//  asked again at once, as Apple advises for a request that can be repeated
//  (QA1941), and a second loss is the server's.
//
//  A tile deeper than the archive is drawn from the archive tile that
//  contains it, so the sixteen tiles of zoom 17 inside one of zoom 15 share
//  one request: archive tiles are kept here for a while, and so is an
//  archive's answer that it has nothing there, both drawn from even while
//  the archive is passed over, and a request already out for one is waited
//  on rather than made again.
//
//  Where the source has extras (``VectorTileSource/Extras``), their tile is
//  asked for beside the basemap's and drawn into it. The extras add to the
//  map and are never its reason to fall back: a tile they do not have adds
//  nothing, and one the server fails to give, or the device loses on the
//  way, leaves the basemap's as it is.
//

import Foundation
import OpenHikesData
import os
import Synchronization

nonisolated final class VectorTileClient: Sendable {
    static let logger = Logger(subsystem: "OpenHikes", category: "VectorTiles")

    /// How long an archive is passed over after it fails, at the least.
    static let failurePause: Duration = .seconds(60)
    /// How long one request may take before it counts as the server failing:
    /// well under the session's own minute, because every tile waiting on
    /// this server is a tile not yet drawn from the fallback.
    static let requestTimeout: TimeInterval = 10
    /// Archive tiles kept in memory, as served, the extras' among them, with
    /// the tiles an archive answered it has nothing at. A zoom-15 tile is
    /// tens of kilobytes, so this is a few megabytes at most.
    static let keptArchiveTiles = 128

    private let sources: [String: VectorTileSource]
    private let session: URLSession
    private let language: String
    private let now: @Sendable () -> ContinuousClock.Instant
    private let state = Mutex(State())

    private struct State {
        /// Until when each archive is passed over, by its address.
        var pausedUntil: [URL: ContinuousClock.Instant] = [:]
        /// By the archive tile's address on the server: its bytes, or the
        /// archive's answer that it has nothing there (``Fetch/missing``).
        var kept: [URL: Fetch] = [:]
        var keptOrder: [URL] = []
        var inFlight: [URL: Task<Fetch, Never>] = [:]
    }

    /// What the tile server made of one tile.
    enum Drawing: Sendable, Equatable {
        /// The tile, drawn, as PNG bytes.
        case png(Data)
        /// Not drawn: the provider's raster template is asked instead.
        case fallBack
        /// The device reached no server, so the raster template is not asked
        /// either: the load fails, and is tried again as any failed load is.
        case offline
    }

    /// What one request for an archive tile came to.
    enum Fetch: Sendable, Equatable {
        case tile(Data)
        /// The archive has nothing there. Kept as a tile is, so the tiles
        /// that share it do not ask again; the fallback draws a basemap's.
        case missing
        /// The server refused this one tile: the fallback draws it, and the
        /// server is still asked for the next.
        case refused
        /// The server is down or failing, and the archive is passed over for
        /// `pause`.
        case unavailable(pause: Duration)
        /// The device's own connection failed: nothing is learnt of the server.
        case offline
    }

    /// Where an archive tile is to be had.
    private enum Lookup {
        /// ``Fetch/tile(_:)`` or ``Fetch/missing``.
        case kept(Fetch)
        case fetching(Task<Fetch, Never>)
        case paused
    }

    /// An archive tile's bytes, by the address they were served from.
    private struct Served {
        let url: URL
        let bytes: Data
    }

    /// - Parameters:
    ///   - sources: the vector source of each provider that has one, by
    ///     provider id.
    ///   - session: the cache's own, so the tile server is told who is asking
    ///     as every tile server is.
    ///   - language: the language whose names the map prefers.
    ///   - now: the clock ``failurePause`` is measured on, injected for tests.
    init(
        sources: [String: VectorTileSource],
        session: URLSession,
        language: String = VectorTileLabels.appLanguage,
        now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }
    ) {
        self.sources = sources
        self.session = session
        self.language = language
        self.now = now
    }

    /// The tile `key` names, drawn, or what to do instead: ``Drawing/fallBack``
    /// when the provider has no vector source or the tile could not be drawn.
    ///
    /// `@concurrent`, because reading and drawing a tile is tens of
    /// milliseconds of work that must not land on whichever actor asked.
    @concurrent
    func drawing(forKey key: String) async -> Drawing {
        guard let named = TileCacheKey.named(key), let source = sources[named.providerID] else { return .fallBack }
        let target = VectorTileAddress(z: named.z, x: named.x, y: named.y)
        let dataTile = source.dataTile(for: target)
        // Both asked for before either is waited on.
        let basemapURL = source.url(of: dataTile)
        let basemap = lookUp(basemapURL, in: source.archiveURL)
        var extras: (url: URL, lookup: Lookup)?
        if let archive = source.extras?.archiveURL, let url = source.extrasURL(of: dataTile) {
            extras = (url, lookUp(url, in: archive))
        }
        switch await Self.result(of: basemap) {
        case let .tile(bytes):
            // Whatever became of the extras, the basemap is drawn.
            var added: Served?
            if let extras, case let .tile(extrasBytes) = await Self.result(of: extras.lookup) {
                added = Served(url: extras.url, bytes: extrasBytes)
            }
            let drawn = draw(Served(url: basemapURL, bytes: bytes), extras: added, from: dataTile, as: target, key: key)
            return drawn.map(Drawing.png) ?? .fallBack
        case .offline:
            return .offline
        case nil:
            #if DEBUG
            Self.logger.debug("Vector tile \(key, privacy: .public): archive passed over after a failure")
            #endif
            return .fallBack
        case .missing, .refused, .unavailable:
            return .fallBack
        }
    }

    /// What a lookup came to, or `nil` where the archive is passed over.
    private static func result(of lookup: Lookup) async -> Fetch? {
        switch lookup {
        case let .kept(fetched): fetched
        case let .fetching(task): await task.value
        case .paused: nil
        }
    }

    /// `basemap`, with the extras' tile drawn into it, drawn as `target`, or
    /// `nil`. Extras that cannot be read are left out rather than costing
    /// the tile.
    private func draw(
        _ basemap: Served,
        extras: Served?,
        from dataTile: VectorTileAddress,
        as target: VectorTileAddress,
        key: String
    ) -> Data? {
        guard var tile = decode(basemap) else { return nil }
        if let extras, let added = decode(extras) {
            tile = tile.merging(added)
        }
        let png = VectorTileRasterizer.png(
            of: tile,
            from: dataTile,
            drawing: target,
            language: language,
            height: { HikeFormat.elevation(Measurement(value: $0, unit: .meters)) }
        )
        #if DEBUG
        let url = basemap.url
        let size = png?.count ?? 0
        Self.logger.debug("Drew tile \(key, privacy: .public) from \(url, privacy: .public) (\(size) bytes)")
        #endif
        return png
    }

    /// `served`, read, or `nil`, with the bytes forgotten: an HTML page
    /// served as a tile, say, which the server may not send twice.
    private func decode(_ served: Served) -> MapboxVectorTile? {
        do {
            return try MapboxVectorTile(
                data: served.bytes,
                layerNames: VectorTileRasterizer.layerNames,
                propertyKeys: VectorTileRasterizer.propertyKeys(language: language)
            )
        } catch {
            forget(served)
            #if DEBUG
            let url = served.url
            let reason = String(describing: error)
            Self.logger.error("Vector tile \(url, privacy: .public) is unreadable: \(reason, privacy: .public)")
            #endif
            return nil
        }
    }

    /// Whether `archive` is being passed over after a failure.
    func isPaused(_ archive: URL) -> Bool {
        let instant = now()
        return state.withLock { state in
            guard let until = state.pausedUntil[archive] else { return false }
            if instant < until { return true }
            state.pausedUntil[archive] = nil
            return false
        }
    }

    /// One tile of `archive`, by its address on the server: kept, already
    /// being fetched, or fetched now unless the archive is being passed over.
    private func lookUp(_ url: URL, in archive: URL) -> Lookup {
        let paused = isPaused(archive)
        return state.withLock { state -> Lookup in
            if let kept = state.kept[url] { return .kept(kept) }
            if let running = state.inFlight[url] { return .fetching(running) }
            if paused { return .paused }
            let task = Task { [weak self] () -> Fetch in
                guard let self else { return .refused }
                let fetched = await request(url)
                finish(url, in: archive, with: fetched)
                return fetched
            }
            state.inFlight[url] = task
            return .fetching(task)
        }
    }

    private func finish(_ url: URL, in archive: URL, with fetched: Fetch) {
        let instant = now()
        state.withLock { state in
            state.inFlight[url] = nil
            switch fetched {
            case .tile, .missing:
                state.kept[url] = fetched
                state.keptOrder.removeAll { $0 == url }
                state.keptOrder.append(url)
                while state.keptOrder.count > Self.keptArchiveTiles {
                    state.kept[state.keptOrder.removeFirst()] = nil
                }
            case let .unavailable(pause):
                // Two requests can fail together, and the one that comes back
                // last must not cut short the longer wait the first was told.
                state.pausedUntil[archive] = max(state.pausedUntil[archive] ?? instant, instant + pause)
            case .refused, .offline:
                break
            }
        }
    }

    /// Drops bytes that could not be read, so the next tile that needs them
    /// asks the server again rather than falling back for as long as they
    /// would be kept. Bytes fetched again since are left alone.
    private func forget(_ served: Served) {
        state.withLock { state in
            guard state.kept[served.url] == .tile(served.bytes) else { return }
            state.kept[served.url] = nil
            state.keptOrder.removeAll { $0 == served.url }
        }
    }

    /// The archive tile at `url`, asked for again at once where the
    /// connection is lost mid-request: see the header.
    private func request(_ url: URL) async -> Fetch {
        let request = URLRequest(url: url, timeoutInterval: Self.requestTimeout)
        do {
            return try await response(to: request)
        } catch let lost as URLError where lost.code == .networkConnectionLost {
            #if DEBUG
            Self.logger.debug("Vector tile \(url, privacy: .public): connection lost, asking again")
            #endif
            do {
                return try await response(to: request)
            } catch {
                return Self.failure(error, for: url)
            }
        } catch {
            return Self.failure(error, for: url)
        }
    }

    private func response(to request: URLRequest) async throws -> Fetch {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { return .unavailable(pause: Self.failurePause) }
        let fetched = Self.outcome(status: http.statusCode, data: data, retryAfter: RetryAfterHeader.delay(from: http))
        #if DEBUG
        if fetched != .tile(data), let url = request.url {
            Self.logger.error("Vector tile \(url, privacy: .public): HTTP \(http.statusCode, privacy: .public)")
        }
        #endif
        return fetched
    }

    /// A request that failed before any response, logged and read.
    private static func failure(_ error: any Error, for url: URL) -> Fetch {
        #if DEBUG
        let reason = error.localizedDescription
        logger.error("Vector tile \(url, privacy: .public) failed: \(reason, privacy: .public)")
        #endif
        return outcome(of: error)
    }

    /// A request that failed before any response, read as the server's
    /// failure or the device's.
    static func outcome(of error: any Error) -> Fetch {
        guard let failure = error as? URLError, deviceFailures.contains(failure.code) else {
            return .unavailable(pause: failurePause)
        }
        return .offline
    }

    /// The failures of the device's own connection: no route at all, and
    /// cellular data refused to the app, abroad or during a call. A timeout
    /// is not among them, because a server that hangs times out too, and nor
    /// is a connection lost mid-request, because a server can drop one.
    private static let deviceFailures: Set<URLError.Code> = [
        .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff, .callIsActive,
    ]

    /// A response read as the server's health and the tile's: a tile, a tile
    /// the archive does not have, one refused, or a server to pass over, for
    /// ``failurePause`` or the longer `retryAfter` it asked for.
    static func outcome(status: Int, data: Data, retryAfter: Duration? = nil) -> Fetch {
        if status == httpOK, !data.isEmpty { return .tile(data) }
        if httpNothingThere.contains(status) { return .missing }
        if status == httpTooManyRequests || httpServerErrors.contains(status) {
            return .unavailable(pause: max(failurePause, retryAfter ?? .zero))
        }
        return .refused
    }

    private static let httpOK = 200
    /// How the OpenHikes tile server says an archive has nothing at a tile:
    /// a 204 inside the archive's zooms, a 404 outside them, and an empty 200
    /// as another server might.
    private static let httpNothingThere: Set<Int> = [httpOK, httpNoContent, httpNotFound]
    private static let httpNoContent = 204
    private static let httpNotFound = 404
    private static let httpTooManyRequests = 429
    private static let httpServerErrors = 500..<600
}
