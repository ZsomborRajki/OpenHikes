//
//  VectorTileClient.swift
//  OpenHikes
//
//  Turns a cache key into a drawn tile, for the providers that have a
//  ``VectorTileSource``: the archive tile off the OpenHikes tile server, drawn
//  by ``VectorTileRasterizer``, as PNG bytes the cache files like any tile.
//
//  `nil` is the fallback, never a blank tile. ``TileCache`` goes on to the
//  provider's raster template, tile.openstreetmap.org for OpenStreetMap, so a
//  hiker sees the old map where the new one cannot be drawn. That covers
//  three cases:
//  - the server is down or failing: a transport error, a timeout, a 5xx or
//    a 429. The server is then passed over for ``failurePause``, so a
//    screenful of tiles does not each wait on it before falling back.
//  - the archive has no tile there.
//  - the tile could not be read or drawn.
//
//  A tile deeper than the archive is drawn from the archive tile that
//  contains it, so the sixteen tiles of zoom 17 inside one of zoom 15 share
//  one request: archive tiles are kept here for a while, and a request
//  already out for one is waited on rather than made again.
//

import Foundation
import OpenHikesData
import os
import Synchronization

nonisolated final class VectorTileClient: Sendable {
    static let logger = Logger(subsystem: "OpenHikes", category: "VectorTiles")

    /// How long the server is passed over after it fails.
    static let failurePause: Duration = .seconds(60)
    /// How long one request may take before it counts as the server failing:
    /// well under the session's own minute, because every tile waiting on
    /// this server is a tile not yet drawn from the fallback.
    static let requestTimeout: TimeInterval = 10
    /// Archive tiles kept in memory, as served. A zoom-15 tile is tens of
    /// kilobytes, so this is a few megabytes at most.
    static let keptArchiveTiles = 64

    private let sources: [String: VectorTileSource]
    private let session: URLSession
    private let language: String
    private let now: @Sendable () -> ContinuousClock.Instant
    private let state = Mutex(State())

    private struct State {
        var pausedUntil: ContinuousClock.Instant?
        var kept: [VectorTileAddress: Data] = [:]
        var keptOrder: [VectorTileAddress] = []
        var inFlight: [VectorTileAddress: Task<Fetch, Never>] = [:]
    }

    /// What one request for an archive tile came to.
    enum Fetch: Sendable, Equatable {
        case tile(Data)
        /// The archive has no tile there, or refused this one: the fallback
        /// draws it, and the server is still asked for the next.
        case missing
        /// The server is down or failing, and is passed over for a while.
        case unavailable
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

    /// The tile `key` names, drawn as PNG bytes, or `nil` when the provider has
    /// no vector source or the tile could not be drawn, for the caller to fall
    /// back to the provider's raster template.
    ///
    /// `@concurrent`, because reading and drawing a tile is tens of
    /// milliseconds of work that must not land on whichever actor asked.
    @concurrent
    func pngData(forKey key: String) async -> Data? {
        guard let named = TileCacheKey.named(key), let source = sources[named.providerID] else { return nil }
        guard !isPaused else {
            #if DEBUG
            Self.logger.debug("Vector tile \(key, privacy: .public): server passed over after a failure")
            #endif
            return nil
        }
        let target = VectorTileAddress(z: named.z, x: named.x, y: named.y)
        let dataTile = source.dataTile(for: target)
        guard case let .tile(bytes) = await archiveTile(dataTile, from: source) else { return nil }
        do {
            let tile = try MapboxVectorTile(
                data: bytes,
                layerNames: VectorTileRasterizer.layerNames,
                propertyKeys: VectorTileRasterizer.propertyKeys(language: language)
            )
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

    /// One archive tile: kept, already being fetched, or fetched now.
    private func archiveTile(_ tile: VectorTileAddress, from source: VectorTileSource) async -> Fetch {
        let task = state.withLock { state -> Task<Fetch, Never>? in
            if state.kept[tile] != nil { return nil }
            if let running = state.inFlight[tile] { return running }
            let task = Task { [weak self] () -> Fetch in
                guard let self else { return .missing }
                let fetched = await request(tile, from: source)
                finish(tile, with: fetched)
                return fetched
            }
            state.inFlight[tile] = task
            return task
        }
        guard let task else {
            return state.withLock { $0.kept[tile] }.map(Fetch.tile) ?? .missing
        }
        return await task.value
    }

    private func finish(_ tile: VectorTileAddress, with fetched: Fetch) {
        let instant = now()
        state.withLock { state in
            state.inFlight[tile] = nil
            switch fetched {
            case let .tile(bytes):
                state.kept[tile] = bytes
                state.keptOrder.removeAll { $0 == tile }
                state.keptOrder.append(tile)
                while state.keptOrder.count > Self.keptArchiveTiles {
                    state.kept[state.keptOrder.removeFirst()] = nil
                }
            case .unavailable:
                state.pausedUntil = instant + Self.failurePause
            case .missing:
                break
            }
        }
    }

    private func request(_ tile: VectorTileAddress, from source: VectorTileSource) async -> Fetch {
        let url = source.url(of: tile)
        do {
            let request = URLRequest(url: url, timeoutInterval: Self.requestTimeout)
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .unavailable }
            let fetched = Self.outcome(status: http.statusCode, data: data)
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
            return .unavailable
        }
    }

    /// A response read as the server's health and the tile's: a tile, a tile
    /// that is not there, or a server to pass over.
    static func outcome(status: Int, data: Data) -> Fetch {
        if status == httpOK, !data.isEmpty { return .tile(data) }
        if status == httpTooManyRequests || httpServerErrors.contains(status) { return .unavailable }
        return .missing
    }

    private static let httpOK = 200
    private static let httpTooManyRequests = 429
    private static let httpServerErrors = 500..<600
}
