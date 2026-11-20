//
//  VectorTileArchives.swift
//  OpenHikes
//
//  The archives the vector providers are drawn from now, and the reading of
//  the tile server's manifest that moves them (`VectorTileArchiveManifest`).
//  A launch draws from the newer of the bundled manifest and the newest one
//  this device has read, which is kept on disk with what it named.
//
//  The manifest is read when the app comes to the front, at most once an
//  hour, and whenever the server answers that an archive it was asked for is
//  gone: a 410, which is what an archive retired since the last read looks
//  like (`VectorTileClient`). A tile that meets a retired archive waits for
//  that read and is drawn from the archive it names, so a build whose names
//  are out of date draws today's map from its first screen rather than the
//  raster fallback.
//
//  The cache files a drawn tile under the provider's key, which says nothing
//  of the archives it was drawn from, so a tile drawn before the archives
//  moved would answer for a week in place of the new build. When they moved
//  is kept with them, and a tile drawn before then is drawn again, as one
//  drawn before a downloaded country was installed is
//  (`OfflineCountryArchives.redraws(_:drawnAt:)`). A later time than the move
//  only redraws more, so a move that could not be written down is simply
//  made again at the next launch.
//

import Foundation
import os
import Synchronization

/// Where the tile server's manifest is read. A suite hands in its own.
protocol VectorTileManifestServing: Sendable {
    /// `@concurrent`, so the read is off the main actor whoever asks.
    @concurrent
    func manifest() async throws -> VectorTileArchiveManifest
}

/// The OpenHikes tile server's manifest, `manifest.json` at its root.
nonisolated struct VectorTileManifestServer: VectorTileManifestServing {
    let root: URL

    enum Failure: Error {
        case status(Int)
    }

    @concurrent
    func manifest() async throws -> VectorTileArchiveManifest {
        var request = URLRequest(
            url: root.appending(path: "manifest.json"),
            cachePolicy: .reloadRevalidatingCacheData,
            timeoutInterval: VectorTileClient.requestTimeout
        )
        request.setValue(TileCache.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == Self.httpOK else { throw Failure.status(status) }
        return try JSONDecoder().decode(VectorTileArchiveManifest.self, from: data)
    }

    private static let httpOK = 200
}

nonisolated final class VectorTileArchives: Sendable {
    // swiftlint:disable:next force_unwrapping
    static let server = URL(string: "https://tiles.openhikes.app/")!
    /// How long after a read the app's coming to the front reads nothing.
    static let readInterval: Duration = .seconds(3600)
    /// How long after a read a retired archive does not have the manifest
    /// read again: one that still names the archive is not mended by asking
    /// at once.
    static let retiredReadInterval: Duration = .seconds(60)

    /// What a device keeps of the manifests it has read.
    struct Kept: Codable, Equatable, Sendable {
        /// The newest one read.
        var manifest: VectorTileArchiveManifest
        /// What this build draws by it.
        var source: VectorTileSource
        /// When the device moved to that.
        var since: Date

        static func read(from file: URL) -> Self? {
            guard let data = try? Data(contentsOf: file) else { return nil }
            return try? JSONDecoder().decode(Self.self, from: data)
        }

        func write(to file: URL) {
            do {
                try FileManager.default.createDirectory(
                    at: file.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try JSONEncoder().encode(self).write(to: file, options: .atomic)
            } catch {
                let reason = String(describing: error)
                VectorTileArchives.logger.error("Keeping the tile archives: \(reason, privacy: .public)")
            }
        }
    }

    private struct State {
        var sources: [String: VectorTileSource]
        var manifest: VectorTileArchiveManifest?
        var since: Date
        /// What is on disk, so that a read which changes nothing writes nothing.
        var written: Kept?
        var reading: Task<Void, Never>?
        var lastRead: ContinuousClock.Instant?
    }

    private static let logger = Logger(subsystem: "OpenHikes", category: "VectorTiles")
    private let state: Mutex<State>
    private let server: URL
    private let manifests: (any VectorTileManifestServing)?
    private let file: URL?
    private let mayAsk: @Sendable () -> Bool
    private let now: @Sendable () -> ContinuousClock.Instant
    private let didMove: @Sendable () -> Void

    private init(
        sources: [String: VectorTileSource],
        since: Date,
        manifest: VectorTileArchiveManifest?,
        written: Kept?,
        server: URL,
        manifests: (any VectorTileManifestServing)?,
        file: URL?,
        mayAsk: @escaping @Sendable () -> Bool,
        now: @escaping @Sendable () -> ContinuousClock.Instant,
        didMove: @escaping @Sendable () -> Void
    ) {
        state = Mutex(State(sources: sources, manifest: manifest, since: since, written: written))
        self.server = server
        self.manifests = manifests
        self.file = file
        self.mayAsk = mayAsk
        self.now = now
        self.didMove = didMove
    }

    /// Fixed `sources`, by provider id, which a read of `manifests` moves,
    /// every one of them, to what the manifest names on `server`.
    convenience init(
        sources: [String: VectorTileSource],
        server: URL = VectorTileArchives.server,
        manifests: (any VectorTileManifestServing)? = nil,
        now: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
        didMove: @escaping @Sendable () -> Void = { /* no-op default */ }
    ) {
        self.init(
            sources: sources,
            since: .distantPast,
            manifest: nil,
            written: nil,
            server: server,
            manifests: manifests,
            file: nil,
            mayAsk: { true },
            now: now,
            didMove: didMove
        )
    }

    /// What a launch draws `providerIDs` from: the newer of `bundled` and the
    /// manifest kept in `file`, or `nil` where neither names a basemap this
    /// build draws.
    ///
    /// - Parameters:
    ///   - manifests: where the manifest is read from then on; `nil` reads none.
    ///   - file: where the newest manifest read is kept; `nil` keeps none.
    ///   - server: where the archives a manifest names are.
    ///   - mayAsk: whether the network may be asked now.
    ///   - now: the clock the read intervals run on.
    ///   - didMove: told after a read has moved the sources, off the main actor.
    ///   - date: the launch, which tiles drawn before are drawn again if this
    ///     launch moved the sources.
    convenience init?(
        providerIDs: Set<String>,
        bundled: VectorTileArchiveManifest,
        manifests: (any VectorTileManifestServing)?,
        file: URL?,
        server: URL = VectorTileArchives.server,
        mayAsk: @escaping @Sendable () -> Bool = { true },
        now: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
        didMove: @escaping @Sendable () -> Void = { /* no-op default */ },
        launchedAt date: Date = Date()
    ) {
        let kept = file.flatMap(Kept.read(from:))
        guard let start = Self.start(bundled: bundled, kept: kept, server: server, at: date) else { return nil }
        self.init(
            sources: Dictionary(uniqueKeysWithValues: providerIDs.map { ($0, start.source) }),
            since: start.since,
            manifest: start.manifest,
            written: kept,
            server: server,
            manifests: manifests,
            file: file,
            mayAsk: mayAsk,
            now: now,
            didMove: didMove
        )
    }

    /// The app's, or `nil` in a suite, which reaches no tile server unless it
    /// is the App Store frames' (``AppLaunchEnvironment/asksTileServer``).
    static func forThisLaunch() -> VectorTileArchives? {
        guard !AppLaunchEnvironment.isRunningTests || AppLaunchEnvironment.asksTileServer,
              let bundled = VectorTileArchiveManifest.bundled else { return nil }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return VectorTileArchives(
            providerIDs: Set(TileProvider.vectorSources.keys),
            bundled: bundled,
            manifests: VectorTileManifestServer(root: server),
            file: support.appending(path: "VectorTileArchives.json"),
            mayAsk: {
                TileNetworkPolicy.decide(.interactive, conditions: TileCache.shared.networkConditions).isAllowed
            },
            // The map draws what it shows again, from the new archives.
            didMove: { TileCache.shared.notifyInteractiveFetchUnblocked() }
        )
    }

    /// What a launch draws from: the kept manifest where it is at least as
    /// new as the bundled one and names something this build draws, as the
    /// server's, and the bundled one otherwise. It moved at `date` unless it
    /// is what the device drew from before.
    static func start(
        bundled: VectorTileArchiveManifest,
        kept: Kept?,
        server: URL,
        at date: Date
    ) -> Kept? {
        let manifest = if let kept, kept.manifest.revision >= bundled.revision,
                          kept.manifest.source(on: server) != nil {
            kept.manifest
        } else {
            bundled
        }
        guard let source = manifest.source(on: server) else { return nil }
        let since = if let kept, kept.source == source { kept.since } else { date }
        return Kept(manifest: manifest, source: source, since: since)
    }

    /// What `providerID` is drawn from now, or `nil` for a provider not drawn
    /// from vector tiles.
    func source(for providerID: String) -> VectorTileSource? {
        state.withLock { $0.sources[providerID] }
    }

    /// Whether the cache's copy of the tile `key` names, drawn at `storedAt`,
    /// is to be drawn again: its provider has moved to other archives since.
    /// Safe in the map's draw pass, which it is asked from.
    func redraws(_ key: String, drawnAt storedAt: Date) -> Bool {
        guard let named = TileCacheKey.named(key) else { return false }
        return state.withLock { $0.sources[named.providerID] != nil && $0.since > storedAt }
    }

    /// Reads the manifest unless it was read within ``readInterval``: the
    /// app coming to the front, which does not wait for it. The read, or
    /// `nil` where none is made.
    @discardableResult func refresh() -> Task<Void, Never>? {
        read(unlessReadWithin: Self.readInterval)
    }

    /// Whether `providerID` is drawn from something other than `source` now,
    /// which the server has answered is gone: at once where a read has
    /// already moved it, and otherwise once the manifest has been read again,
    /// unless it was within ``retiredReadInterval``.
    func moved(from source: VectorTileSource, for providerID: String) async -> Bool {
        if self.source(for: providerID) != source { return true }
        await read(unlessReadWithin: Self.retiredReadInterval)?.value
        return self.source(for: providerID) != source
    }

    /// Moves every provider to what `manifest` names, where it is at least as
    /// new as the one they come from and names a basemap this build draws,
    /// and keeps it.
    func adopt(_ manifest: VectorTileArchiveManifest) {
        guard let source = manifest.source(on: server) else {
            Self.logger.error("Tile server manifest \(manifest.revision) names nothing this build draws")
            return
        }
        let date = Date()
        let (moved, kept) = state.withLock { state -> (Bool, Kept?) in
            if let current = state.manifest, manifest.revision < current.revision { return (false, nil) }
            let moved = state.sources.values.contains { $0 != source }
            if moved {
                state.sources = state.sources.mapValues { _ in source }
                state.since = date
            }
            state.manifest = manifest
            let kept = Kept(manifest: manifest, source: source, since: state.since)
            guard file != nil, kept != state.written else { return (moved, nil) }
            state.written = kept
            return (moved, kept)
        }
        if let kept, let file { kept.write(to: file) }
        if moved { didMove() }
    }

    /// The read under way, joined, or one started unless the last ended
    /// within `interval`. `nil` where nothing is read.
    private func read(unlessReadWithin interval: Duration) -> Task<Void, Never>? {
        guard manifests != nil else { return nil }
        let instant = now()
        return state.withLock { state in
            if let reading = state.reading { return reading }
            if let last = state.lastRead, instant - last < interval { return nil }
            let task = Task { [weak self] in
                guard let self else { return }
                await readManifest()
            }
            state.reading = task
            return task
        }
    }

    private func readManifest() async {
        // A read the network refused has not been made, so the next reason
        // to read asks again.
        let asked = mayAsk()
        if asked, let manifests {
            do {
                adopt(try await manifests.manifest())
            } catch {
                let reason = String(describing: error)
                Self.logger.error("Reading the tile server's manifest: \(reason, privacy: .public)")
            }
        }
        let instant = now()
        state.withLock { state in
            state.reading = nil
            if asked { state.lastRead = instant }
        }
    }
}
