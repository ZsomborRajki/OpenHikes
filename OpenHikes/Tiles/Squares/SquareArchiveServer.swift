//
//  SquareArchiveServer.swift
//  OpenHikes
//
//  One set of OpenStreetMap's pre-built squares on the OpenHikes tile
//  server: which archive of it to read, and its squares, answered as the
//  public database answered for them (``TrailCellFetching``), so each set's
//  own library reads them as it always did: ``TrailCellLibrary``,
//  ``HikingRouteSquares``, ``PlaceSquareLibrary`` and
//  ``TrailGraphSquareLibrary``. See ``SquareArchive`` for what an archive
//  is, and which tile of it a square is.
//
//  ## Which archive
//
//  The tile server's manifest, `manifest.json` at its root, names the
//  archives the map is drawn from (`VectorTileArchiveManifest`) and, under a
//  list for each set, the squares', newest first, each with the generation
//  of the files its tiles hold and their deepest zoom. This reads the first
//  of its set's that this build reads. It starts from the list the app
//  bundles (`VectorTileArchiveManifest.json`), reads the server's the first
//  time it is asked for a square and an hour after each read, and reads it
//  at once, at most once a minute, when the server answers that the archive
//  is gone: a 410, which is what an archive retired since the last read
//  looks like. The square is then asked of the archive the new list names.
//
//  ## What the answers mean
//
//  - A tile is the square's file.
//  - No tile (a 204) is ground with nothing on it: only a build of the whole
//    planet goes up (`Scripts/trail-cells.sh upload-archive`), so every
//    archive the server lists is the whole world, which is the public
//    database's manifest saying the squares are complete.
//  - No archive this build reads is no answer: the library goes on as it did
//    before there were squares, asking Overpass where it can.
//  - Anything else is a square that could not be read. When every square
//    asked for in one call fails to arrive at all, the call throws, as a
//    request to the public database did that failed as a whole.
//  - A call that is cancelled throws `CancellationError`, whatever had
//    arrived, as the public database's request did: a search superseded
//    while its squares were out is no answer, and none of them failed.
//
//  A call's squares are asked for several at a time, because the day hikes'
//  widest search reads hundreds, and the server answers each in its own
//  request. Two things hold for the call as a whole:
//
//  - **One archive.** When a square's archive turns out to be retired, every
//    square of the call is asked again of the archive the list names now,
//    not only the retired ones: a place or a route that moved from one
//    square to another between two builds would otherwise be in neither
//    square of the answer, and the library keeps both.
//  - **One deadline**, the library's limit for a whole request, as the
//    public database had: a server that stops answering would otherwise
//    hold a search for a wave of request timeouts after another, while the
//    hiker waits for Overpass. When it passes, what is out is cancelled,
//    nothing more is asked, and the squares that arrived are kept.
//
//  ## No suite reaches it
//
//  Every `…ForThisLaunch()` that builds one is `nil` under
//  ``AppLaunchEnvironment/isRunningTests``. A suite hands this a transport
//  of its own.
//

import Foundation
import os
import Synchronization

nonisolated final class SquareArchiveServer: TrailCellFetching {
    private static let logger = Logger(subsystem: "OpenHikes", category: "SquareArchives")

    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    /// The part of the tile server's manifest this reads: every set's list.
    struct Listing: Codable, Equatable, Sendable {
        struct Archive: Codable, Equatable, Sendable {
            /// Its name on the server, without `.pmtiles`.
            var name: String
            /// ``SquareArchive/generation``'s, for the files it holds.
            var generation: Int
            /// The deepest zoom of its tiles.
            var zoom: Int

            /// Whether this build reads it as one of `set`'s: of the set's
            /// generation and zoom, under a name of the set's it asks the
            /// server for.
            func isRead(as set: SquareArchive) -> Bool {
                generation == set.generation && zoom == set.zoom && set.isArchiveName(name)
            }
        }

        /// The manifest's format, `VectorTileArchiveManifest.currentVersion`'s.
        var version: Int
        /// Raised by every publish, so that of two lists the newer is known.
        var revision: Int
        /// Each set's archives, newest first. A set the manifest has no list
        /// for has none: a manifest from before its squares went up.
        var archives: [SquareArchive: [Archive]]

        init(version: Int, revision: Int, archives: [SquareArchive: [Archive]]) {
            self.version = version
            self.revision = revision
            self.archives = archives
        }

        /// The archive of `set` this build reads, or `nil` for none.
        func archive(of set: SquareArchive) -> String? {
            guard version == Self.readVersion else { return nil }
            return archives[set]?.first { $0.isRead(as: set) }?.name
        }

        private struct Key: CodingKey {
            var stringValue: String
            var intValue: Int? { nil }

            init(_ string: String) { stringValue = string }
            init?(stringValue: String) { self.init(stringValue) }
            init?(intValue _: Int) { nil }

            static let version = Self("version")
            static let revision = Self("revision")
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: Key.self)
            version = try container.decode(Int.self, forKey: .version)
            revision = try container.decode(Int.self, forKey: .revision)
            var lists: [SquareArchive: [Archive]] = [:]
            for kind in SquareArchive.allCases {
                lists[kind] = try container.decodeIfPresent([Archive].self, forKey: Key(kind.listName))
            }
            archives = lists
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: Key.self)
            try container.encode(version, forKey: .version)
            try container.encode(revision, forKey: .revision)
            for kind in SquareArchive.allCases {
                try container.encodeIfPresent(archives[kind], forKey: Key(kind.listName))
            }
        }

        private static let readVersion = VectorTileArchiveManifest.currentVersion

        /// The list the app was built with, or `nil` if it cannot be read.
        static let bundled: Self? = {
            guard let url = VectorTileArchiveManifest.bundledURL,
                  let data = try? Data(contentsOf: url)
            else { return nil }
            return try? JSONDecoder().decode(Self.self, from: data)
        }()
    }

    /// A server answer that is no tile, no empty ground and no retired
    /// archive.
    enum Failure: Error, Equatable {
        case status(Int)
        case notHTTP
        /// The call's deadline passed before any of its squares arrived.
        case timedOut
    }

    /// How long after a read of the server's list the next square reads it
    /// again, and how long after one a retired archive does not: the map's.
    static let readInterval = TimeInterval(VectorTileArchives.readInterval.components.seconds)
    static let retiredReadInterval = TimeInterval(VectorTileArchives.retiredReadInterval.components.seconds)

    /// How many of a call's squares are asked for at once.
    static let concurrentRequests = 8

    private struct State {
        var listing: Listing?
        /// When the server's list was last asked for, read or not.
        var lastRead: Date?
        /// The read of the list under way, which every square that wants the
        /// list meanwhile waits on.
        var reading: Task<Void, Never>?
    }

    /// What the server said about one square.
    private enum Answer: Equatable {
        case cell(TrailCellFetch.Cell)
        /// The archive is gone: a 410.
        case retired
    }

    /// What one of a call's tasks came back with.
    private enum Event {
        case answered(String, Result<Answer, any Error>)
        /// The call's deadline passed.
        case expired
    }

    /// The set this reads.
    let set: SquareArchive
    private let server: URL
    /// How long one square's request may go quiet, in seconds.
    let requestTimeout: TimeInterval
    /// How long one call may take in all, its squares together, in seconds,
    /// or `nil` for no limit but each request's own.
    let callTimeout: TimeInterval?
    private let transport: Transport
    private let clock: @Sendable () -> Date
    private let waitOut: @Sendable (TimeInterval) async -> Void
    private let state: Mutex<State>

    /// - Parameters:
    ///   - requestTimeout: How long one square's request may go quiet, the
    ///     set's library's figure: the live transport takes the same, with
    ///     the library's limit for the whole request.
    ///   - callTimeout: How long one call may take in all: the library's
    ///     limit for the whole request, as a request to the public database
    ///     was held to.
    ///   - waitOut: Returns once the given seconds have passed, or once the
    ///     task waiting is cancelled. A suite passes one it ends itself.
    init(
        set: SquareArchive,
        server: URL,
        bundled: Listing?,
        requestTimeout: TimeInterval,
        callTimeout: TimeInterval? = nil,
        clock: @escaping @Sendable () -> Date = { Date() },
        waitOut: @escaping @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) },
        transport: @escaping Transport
    ) {
        self.set = set
        self.server = server
        self.requestTimeout = requestTimeout
        self.callTimeout = callTimeout
        self.transport = transport
        self.clock = clock
        self.waitOut = waitOut
        state = Mutex(State(listing: bundled))
    }

    /// The archive asked for now, or `nil` for none this build reads.
    var archive: String? {
        state.withLock { $0.listing?.archive(of: set) }
    }

    @concurrent
    func fetch(cellsNamed names: [String]) async throws -> TrailCellFetch {
        let deadline = callTimeout.map { clock().addingTimeInterval($0) }
        try await readListing(unlessReadWithin: Self.readInterval)
        guard let asked = archive else { return TrailCellFetch(manifest: .absent, cells: [:]) }
        var found = try await answers(for: names, in: asked, until: deadline)
        if found.values.contains(.retired) {
            // Retired since the list was read: read it again, and ask the
            // archive it names now, if it names another, for every square of
            // the call, so that all of them are one build's.
            try await readListing(unlessReadWithin: Self.retiredReadInterval)
            guard let next = archive else { return TrailCellFetch(manifest: .absent, cells: [:]) }
            guard next != asked else { return TrailCellFetch(manifest: .unread, cells: [:]) }
            found = try await answers(for: names, in: next, until: deadline)
            guard !found.values.contains(.retired) else { return TrailCellFetch(manifest: .unread, cells: [:]) }
        }
        return TrailCellFetch(manifest: .complete, cells: found.compactMapValues { answer in
            guard case .cell(let cell) = answer else { return nil }
            return cell
        })
    }

    /// What the server says of each of `names` in `archive`, several at a
    /// time, until `deadline`. A square whose request failed, or that the
    /// deadline left unanswered, is ``TrailCellFetch/Cell/failed``, unless no
    /// square arrived at all, which throws.
    private func answers(
        for names: [String],
        in archive: String,
        until deadline: Date?
    ) async throws -> [String: Answer] {
        var unnamed: [String: Answer] = [:]
        var asked: [(name: String, tile: SquareArchiveTile)] = []
        for name in names {
            if let tile = set.tile(named: name) {
                asked.append((name, tile))
            } else {
                unnamed[name] = .cell(.failed)
            }
        }
        guard !asked.isEmpty else { return unnamed }
        var batch = await ask(asked, in: archive, until: deadline)
        // A call given up on is no answer, however many of its squares came:
        // the rest were cancelled with it, not refused, and read as squares
        // that could not be read they would send a superseded search on to
        // Overpass and log a server that never failed.
        try Task.checkCancellation()
        // Never asked: the deadline came first.
        for (name, _) in asked where batch.answers[name] == nil {
            batch.answers[name] = .cell(.failed)
        }
        if batch.arrived == 0 {
            if batch.expired { throw Failure.timedOut }
            if let first = batch.failures.first { throw first }
        }
        log(batch, of: asked.count)
        return batch.answers.merging(unnamed) { asked, _ in asked }
    }

    /// What one call's requests to one archive came to.
    private struct Batch {
        var answers: [String: Answer] = [:]
        var failures: [any Error] = []
        /// How many squares the server answered for.
        var arrived = 0
        /// Whether the deadline passed with requests out.
        var expired = false

        mutating func record(_ event: Event) {
            guard case let .answered(name, result) = event else { return }
            switch result {
            case .success(let answer):
                arrived += 1
                answers[name] = answer
            case .failure(let error):
                failures.append(error)
                answers[name] = .cell(.failed)
            }
        }
    }

    /// `asked`, ``concurrentRequests`` at a time, until `deadline`: then
    /// what is out is cancelled and nothing more is asked.
    private func ask(
        _ asked: [(name: String, tile: SquareArchiveTile)],
        in archive: String,
        until deadline: Date?
    ) async -> Batch {
        var batch = Batch()
        await withTaskGroup(of: Event.self) { group in
            var waiting = asked.makeIterator()
            var outstanding = 0
            func addNext() {
                guard !batch.expired, let (name, tile) = waiting.next() else { return }
                outstanding += 1
                group.addTask {
                    do {
                        return .answered(name, .success(try await self.answer(tile, in: archive)))
                    } catch {
                        return .answered(name, .failure(error))
                    }
                }
            }
            if let deadline {
                let seconds = max(0, deadline.timeIntervalSince(clock()))
                group.addTask {
                    await self.waitOut(seconds)
                    return .expired
                }
            }
            for _ in 0..<Self.concurrentRequests {
                addNext()
            }
            for await event in group {
                if case .expired = event {
                    // Every square answered first, and the wait was ended.
                    guard outstanding > 0 else { continue }
                    batch.expired = true
                    group.cancelAll()
                } else {
                    outstanding -= 1
                    batch.record(event)
                    addNext()
                }
                // The deadline's wait is the last task left.
                if outstanding == 0 { group.cancelAll() }
            }
        }
        return batch
    }

    private func log(_ batch: Batch, of count: Int) {
        let list = set.listName
        if batch.expired {
            Self.logger.error(
                "\(count - batch.arrived, privacy: .public) \(list, privacy: .public) squares ran out of time"
            )
        } else if let first = batch.failures.first {
            let reason = String(describing: first)
            Self.logger.error(
                """
                \(batch.failures.count, privacy: .public) of \(count, privacy: .public) \(list, privacy: .public) \
                squares failed: \(reason, privacy: .public)
                """
            )
        }
    }

    /// One tile of `archive`.
    private func answer(_ tile: SquareArchiveTile, in archive: String) async throws -> Answer {
        let url = server.appending(path: SquareArchive.path(of: tile, inArchive: archive))
        let (data, response) = try await transport(request(url))
        switch response.statusCode {
        // No square the build writes is empty, so an empty 200 is a server or
        // a cache saying there is nothing, as the map reads one
        // (`VectorTileClient.outcome(status:data:retryAfter:)`).
        case Self.ok where data.isEmpty: return .cell(.absent)
        case Self.ok: return .cell(.found(data))
        case Self.noContent: return .cell(.absent)
        case Self.gone: return .retired
        default: throw Failure.status(response.statusCode)
        }
    }

    /// Reads the server's list unless it was asked for within `interval`,
    /// and keeps it unless it is older than the one held. A read that fails
    /// keeps the list held, and waits as long as one that did not.
    ///
    /// A read under way is waited on rather than passed by, so a square asked
    /// for meanwhile is asked of the archive the new list names, not of one
    /// it may have retired. And it is a task of its own, which no square's
    /// cancellation reaches: a region given up on while the list was read
    /// would otherwise end the read, and leave the list unread for as long
    /// as a read that had finished. A square that is cancelled stops waiting
    /// at once, and throws `CancellationError`.
    private func readListing(unlessReadWithin interval: TimeInterval) async throws {
        let now = clock()
        let reading = state.withLock { state -> Task<Void, Never>? in
            if let reading = state.reading { return reading }
            if let last = state.lastRead, now.timeIntervalSince(last) < interval, now >= last { return nil }
            state.lastRead = now
            let reading = Task { await self.fetchListing() }
            state.reading = reading
            return reading
        }
        if let reading { await Self.wait(for: reading) }
        try Task.checkCancellation()
    }

    /// Returns when `reading` has finished, or as soon as the task waiting
    /// is cancelled, so a region given up on does not wait out a read it no
    /// longer needs.
    private static func wait(for reading: Task<Void, Never>) async {
        let (finished, finish) = AsyncStream.makeStream(of: Void.self)
        Task {
            await reading.value
            finish.finish()
        }
        for await _ in finished {
            // Nothing is ever sent: the loop ends when the stream does, or
            // when this task is cancelled.
        }
    }

    @concurrent
    private func fetchListing() async {
        defer { state.withLock { $0.reading = nil } }
        do {
            let (data, response) = try await transport(request(server.appending(path: "manifest.json")))
            guard response.statusCode == Self.ok else { throw Failure.status(response.statusCode) }
            let read = try JSONDecoder().decode(Listing.self, from: data)
            state.withLock { state in
                if let held = state.listing, read.revision < held.revision { return }
                state.listing = read
            }
        } catch {
            let reason = String(describing: error)
            let list = set.listName
            Self.logger.error(
                "The tile server's list of \(list, privacy: .public) squares was not read: \(reason, privacy: .public)"
            )
        }
    }

    private func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: requestTimeout)
        request.setValue(TileCache.userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    private static let ok = 200
    private static let noContent = 204
    private static let gone = 410
}

nonisolated extension SquareArchiveServer {
    /// `set`'s squares on the OpenHikes tile server, as a launch reads them:
    /// from the list the app bundles until the server's is read, in a
    /// session of its own with the library's timeouts.
    ///
    /// Only a `…ForThisLaunch()` calls this, behind
    /// ``AppLaunchEnvironment/isRunningTests``.
    static func live(
        _ set: SquareArchive,
        requestTimeout: TimeInterval,
        resourceTimeout: TimeInterval
    ) -> SquareArchiveServer {
        SquareArchiveServer(
            set: set,
            server: VectorTileArchives.server,
            bundled: Listing.bundled,
            requestTimeout: requestTimeout,
            callTimeout: resourceTimeout,
            transport: liveTransport(requestTimeout: requestTimeout, resourceTimeout: resourceTimeout)
        )
    }

    /// A session of its own, with no cache: every library keeps the squares
    /// it reads, on disk or, for the trail graph, as the regions read out of
    /// them.
    static func liveTransport(requestTimeout: TimeInterval, resourceTimeout: TimeInterval) -> Transport {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        return { request in
            let (data, answer) = try await session.data(for: request)
            guard let response = answer as? HTTPURLResponse else { throw Failure.notHTTP }
            return (data, response)
        }
    }
}
