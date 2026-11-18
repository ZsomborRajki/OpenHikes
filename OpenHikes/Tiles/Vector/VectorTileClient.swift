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
//    a 429. The server is then passed over for ``failurePause``, or for as
//    long as its `Retry-After` asks where ``RetryAfterHeader`` honors one,
//    so a screenful of tiles does not each wait on it before falling back.
//  - the archive has no tile there.
//  - the tile could not be read or drawn.
//
//  A failure of the device's own connection is not the server's: no route,
//  a connection dropped between networks, cellular data off for the app. It
//  pauses nothing and falls back to nothing (``Drawing/offline``), because
//  the raster template would fail the same way, and a raster tile that came
//  back would be filed for a week among the drawn ones.
//
//  A tile deeper than the archive is drawn from the archive tile that
//  contains it, so the sixteen tiles of zoom 17 inside one of zoom 15 share
//  one request: archive tiles are kept here for a while, and drawn from even
//  while the server is passed over, and a request already out for one is
//  waited on rather than made again.
//
//  Where the source has extras (``VectorTileSource/Extras``), their tile is
//  asked for beside the basemap's and drawn into it. The extras add to the
//  map and are never its reason to fall back: a tile they do not have adds
//  nothing, and one the server fails to give leaves the basemap's as it is.
//

import Foundation
import OpenHikesData
import os
import Synchronization

nonisolated final class VectorTileClient: Sendable {
    static let logger = Logger(subsystem: "OpenHikes", category: "VectorTiles")

    /// How long the server is passed over after it fails, at the least.
    static let failurePause: Duration = .seconds(60)
    /// How long one request may take before it counts as the server failing:
    /// well under the session's own minute, because every tile waiting on
    /// this server is a tile not yet drawn from the fallback.
    static let requestTimeout: TimeInterval = 10
    /// Archive tiles kept in memory, as served, the extras' among them. A
    /// zoom-15 tile is tens of kilobytes, so this is a few megabytes at most.
    static let keptArchiveTiles = 128

    private let sources: [String: VectorTileSource]
    private let session: URLSession
    private let language: String
    private let now: @Sendable () -> ContinuousClock.Instant
    private let state = Mutex(State())

    private struct State {
        var pausedUntil: ContinuousClock.Instant?
        /// By the archive tile's address on the server.
        var kept: [URL: Data] = [:]
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
        /// The archive has no tile there, or refused this one: the fallback
        /// draws it, and the server is still asked for the next.
        case missing
        /// The server is down or failing, and is passed over for `pause`.
        case unavailable(pause: Duration)
        /// The device's own connection failed: nothing is learnt of the server.
        case offline
    }

    /// Where an archive tile is to be had.
    private enum Lookup {
        case kept(Data)
        case fetching(Task<Fetch, Never>)
        case paused
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
        let basemap = lookUp(source.url(of: dataTile))
        let extras = source.extrasURL(of: dataTile).map(lookUp)
        guard let fetched = await Self.result(of: basemap) else {
            #if DEBUG
            Self.logger.debug("Vector tile \(key, privacy: .public): server passed over after a failure")
            #endif
            return .fallBack
        }
        switch fetched {
        case let .tile(bytes):
            var added: Data?
            if let extras {
                switch await Self.result(of: extras) {
                case let .tile(bytes): added = bytes
                case .offline: return .offline
                case .missing, .unavailable, nil: break
                }
            }
            let drawn = draw(bytes, extras: added, from: dataTile, of: source, as: target, key: key)
            return drawn.map(Drawing.png) ?? .fallBack
        case .offline:
            return .offline
        case .missing, .unavailable:
            return .fallBack
        }
    }

    /// What a lookup came to, or `nil` where the server is passed over.
    private static func result(of lookup: Lookup) async -> Fetch? {
        switch lookup {
        case let .kept(bytes): .tile(bytes)
        case let .fetching(task): await task.value
        case .paused: nil
        }
    }

    /// `bytes`, the archive tile at `dataTile`, with the extras' tile drawn
    /// into it, drawn as `target`, or `nil`. Extras that cannot be read are
    /// left out rather than costing the tile.
    private func draw(
        _ bytes: Data,
        extras: Data?,
        from dataTile: VectorTileAddress,
        of source: VectorTileSource,
        as target: VectorTileAddress,
        key: String
    ) -> Data? {
        do {
            let layerNames = VectorTileRasterizer.layerNames
            let propertyKeys = VectorTileRasterizer.propertyKeys(language: language)
            var tile = try MapboxVectorTile(data: bytes, layerNames: layerNames, propertyKeys: propertyKeys)
            if let extras,
               let added = try? MapboxVectorTile(data: extras, layerNames: layerNames, propertyKeys: propertyKeys) {
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
            let archiveURL = source.url(of: dataTile)
            let size = png?.count ?? 0
            Self.logger.debug("Drew tile \(key, privacy: .public) from \(archiveURL, privacy: .public) (\(size) bytes)")
            #endif
            return png
        } catch {
            #if DEBUG
            let reason = String(describing: error)
            Self.logger.error("Vector tile \(key, privacy: .public) is unreadable: \(reason, privacy: .public)")
            #endif
            return nil
        }
    }

    /// Whether the server is being passed over after a failure.
    var isPaused: Bool {
        let instant = now()
        return state.withLock { state in
            guard let until = state.pausedUntil else { return false }
            if instant < until { return true }
            state.pausedUntil = nil
            return false
        }
    }

    /// One archive tile, by its address on the server: kept, already being
    /// fetched, or fetched now unless the server is being passed over.
    private func lookUp(_ url: URL) -> Lookup {
        let paused = isPaused
        return state.withLock { state -> Lookup in
            if let bytes = state.kept[url] { return .kept(bytes) }
            if let running = state.inFlight[url] { return .fetching(running) }
            if paused { return .paused }
            let task = Task { [weak self] () -> Fetch in
                guard let self else { return .missing }
                let fetched = await request(url)
                finish(url, with: fetched)
                return fetched
            }
            state.inFlight[url] = task
            return .fetching(task)
        }
    }

    private func finish(_ url: URL, with fetched: Fetch) {
        let instant = now()
        state.withLock { state in
            state.inFlight[url] = nil
            switch fetched {
            case let .tile(bytes):
                state.kept[url] = bytes
                state.keptOrder.removeAll { $0 == url }
                state.keptOrder.append(url)
                while state.keptOrder.count > Self.keptArchiveTiles {
                    state.kept[state.keptOrder.removeFirst()] = nil
                }
            case let .unavailable(pause):
                // Two requests can fail together, and the one that comes back
                // last must not cut short the longer wait the first was told.
                state.pausedUntil = max(state.pausedUntil ?? instant, instant + pause)
            case .missing, .offline:
                break
            }
        }
    }

    private func request(_ url: URL) async -> Fetch {
        do {
            let request = URLRequest(url: url, timeoutInterval: Self.requestTimeout)
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .unavailable(pause: Self.failurePause) }
            let fetched = Self.outcome(
                status: http.statusCode,
                data: data,
                retryAfter: RetryAfterHeader.delay(from: http)
            )
            #if DEBUG
            if fetched != .tile(data) {
                Self.logger.error("Vector tile \(url, privacy: .public): HTTP \(http.statusCode, privacy: .public)")
            }
            #endif
            return fetched
        } catch {
            #if DEBUG
            let reason = error.localizedDescription
            Self.logger.error("Vector tile \(url, privacy: .public) failed: \(reason, privacy: .public)")
            #endif
            return Self.outcome(of: error)
        }
    }

    /// A request that failed before any response, read as the server's
    /// failure or the device's.
    static func outcome(of error: any Error) -> Fetch {
        guard let failure = error as? URLError, deviceFailures.contains(failure.code) else {
            return .unavailable(pause: failurePause)
        }
        return .offline
    }

    /// The failures of the device's own connection: no route at all, a
    /// connection dropped as the phone moved between networks, and cellular
    /// data refused to the app, abroad or during a call. A timeout is not
    /// among them: a server that hangs times out too.
    private static let deviceFailures: Set<URLError.Code> = [
        .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff, .callIsActive,
    ]

    /// A response read as the server's health and the tile's: a tile, a tile
    /// that is not there, or a server to pass over, for ``failurePause`` or
    /// the longer `retryAfter` it asked for.
    static func outcome(status: Int, data: Data, retryAfter: Duration? = nil) -> Fetch {
        if status == httpOK, !data.isEmpty { return .tile(data) }
        if status == httpTooManyRequests || httpServerErrors.contains(status) {
            return .unavailable(pause: max(failurePause, retryAfter ?? .zero))
        }
        return .missing
    }

    private static let httpOK = 200
    private static let httpTooManyRequests = 429
    private static let httpServerErrors = 500..<600
}
