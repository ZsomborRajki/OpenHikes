//
//  RoutingGraphServer.swift
//  OpenHikes
//
//  The trail maker's graph on the OpenHikes tile server: which archive of it
//  to read, and one of its tiles, answered as the public database answers
//  for a square (``TrailCellFetching``), so the trail graph's own library
//  reads it (``TrailGraphSquareLibrary/Layout/routing``). See
//  ``RoutingGraphArchive`` for what an archive is.
//
//  ## Which archive
//
//  The tile server's manifest, `manifest.json` at its root, names the
//  archives the map is drawn from (`VectorTileArchiveManifest`) and, under
//  `routing`, the trail maker's, newest first, each with the generation of
//  the files its tiles hold and their zoom. This reads the first one this
//  build reads. It starts from the list the app bundles
//  (`VectorTileArchiveManifest.json`), reads the server's the first time it
//  is asked for a tile and an hour after each read, and reads it at once,
//  at most once a minute, when the server answers that the archive is gone:
//  a 410, which is what an archive retired since the last read looks like.
//  The tile is then asked of the archive the new list names.
//
//  ## What the answers mean
//
//  - A tile is the region's ways, as a square holds them.
//  - No tile (a 204) is ground with no ways on it: only a build of the whole
//    planet goes up (`Scripts/trail-cells.sh upload-routing`), so every
//    archive the server lists is the whole world.
//  - No archive this build reads is no answer: the library leaves the
//    region to Overpass, as every region was before there was an archive.
//  - Anything else is a server that could not answer: the library leaves the
//    tile for a minute, and the region goes to Overpass meanwhile.
//
//  The provider keeps every region it reads for thirty days, and a tile is a
//  region, so nothing here is kept on disk.
//
//  ## No suite reaches it
//
//  ``TrailGraphSquareLibrary/routingForThisLaunch()`` is `nil` under
//  ``AppLaunchEnvironment/isRunningTests``. A suite hands this a transport
//  of its own.
//

import Foundation
import os
import Synchronization

nonisolated final class RoutingGraphServer: TrailCellFetching {
    private static let logger = Logger(subsystem: "OpenHikes", category: "RoutingGraph")

    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    /// The part of the tile server's manifest this reads.
    struct Listing: Codable, Equatable, Sendable {
        struct Archive: Codable, Equatable, Sendable {
            /// Its name on the server, without `.pmtiles`.
            var name: String
            /// ``RoutingGraphArchive/generation``'s, for the files it holds.
            var generation: Int
            /// The zoom of its tiles.
            var zoom: Int

            /// Whether this build reads it: of its generation and zoom, under
            /// a name it asks the server for.
            var isRead: Bool {
                generation == RoutingGraphArchive.generation
                    && zoom == RoutingGraphArchive.zoom
                    && RoutingGraphArchive.isArchiveName(name)
            }
        }

        /// The manifest's format, `VectorTileArchiveManifest.currentVersion`'s.
        var version: Int
        /// Raised by every publish, so that of two lists the newer is known.
        var revision: Int
        /// Newest first. Empty for a manifest from before the maker's
        /// archive, which has no such list.
        var routing: [Archive]

        /// The archive this build reads, or `nil` for none.
        var archive: String? {
            guard version == Self.readVersion else { return nil }
            return routing.first(where: \.isRead)?.name
        }

        init(version: Int, revision: Int, routing: [Archive]) {
            self.version = version
            self.revision = revision
            self.routing = routing
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decode(Int.self, forKey: .version)
            revision = try container.decode(Int.self, forKey: .revision)
            routing = try container.decodeIfPresent([Archive].self, forKey: .routing) ?? []
        }

        private static let readVersion = 1

        /// The list the app was built with, or `nil` if it cannot be read.
        static let bundled: Self? = {
            guard let url = Bundle.main.url(forResource: "VectorTileArchiveManifest", withExtension: "json"),
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
    }

    /// How long after a read of the server's list the next tile reads it
    /// again, and how long after one a retired archive does not: the map's
    /// figures, `VectorTileArchives.readInterval` and `retiredReadInterval`.
    static let readInterval: TimeInterval = 3600
    static let retiredReadInterval: TimeInterval = 60

    private struct State {
        var listing: Listing?
        /// When the server's list was last asked for, read or not.
        var lastRead: Date?
    }

    private let server: URL
    private let transport: Transport
    private let clock: @Sendable () -> Date
    private let state: Mutex<State>

    init(
        server: URL,
        bundled: Listing?,
        clock: @escaping @Sendable () -> Date = { Date() },
        transport: @escaping Transport = RoutingGraphServer.liveTransport()
    ) {
        self.server = server
        self.transport = transport
        self.clock = clock
        state = Mutex(State(listing: bundled))
    }

    /// The archive asked for now, or `nil` for none this build reads.
    var archive: String? {
        state.withLock { $0.listing?.archive }
    }

    @concurrent
    func fetch(cellsNamed names: [String]) async throws -> TrailCellFetch {
        await readListing(unlessReadWithin: Self.readInterval)
        guard var asked = archive else { return TrailCellFetch(manifest: .absent, cells: [:]) }
        var cells: [String: TrailCellFetch.Cell] = [:]
        for name in names {
            guard let tile = RoutingGraphArchive.tile(named: name) else {
                cells[name] = .failed
                continue
            }
            if let found = try await cell(tile, in: asked) {
                cells[name] = found
                continue
            }
            // Retired since the list was read: read it again, and ask the
            // archive it names now, if it names another.
            await readListing(unlessReadWithin: Self.retiredReadInterval)
            guard let next = archive else { return TrailCellFetch(manifest: .absent, cells: [:]) }
            guard next != asked, let found = try await cell(tile, in: next) else {
                return TrailCellFetch(manifest: .unread, cells: [:])
            }
            asked = next
            cells[name] = found
        }
        return TrailCellFetch(manifest: .complete, cells: cells)
    }

    /// One tile of `archive`, or `nil` when the server answers that the
    /// archive is gone.
    private func cell(_ tile: TrailGraphSquare, in archive: String) async throws -> TrailCellFetch.Cell? {
        let url = server.appending(path: RoutingGraphArchive.path(of: tile, inArchive: archive))
        let (data, response) = try await transport(Self.request(url))
        switch response.statusCode {
        case Self.ok: return .found(data)
        case Self.noContent: return .absent
        case Self.gone: return nil
        default: throw Failure.status(response.statusCode)
        }
    }

    /// Reads the server's list unless it was asked for within `interval`,
    /// and keeps it unless it is older than the one held. A read that fails
    /// keeps the list held, and waits as long as one that did not.
    private func readListing(unlessReadWithin interval: TimeInterval) async {
        let now = clock()
        let due = state.withLock { state -> Bool in
            if let last = state.lastRead, now.timeIntervalSince(last) < interval, now >= last { return false }
            state.lastRead = now
            return true
        }
        guard due else { return }
        do {
            let (data, response) = try await transport(Self.request(server.appending(path: "manifest.json")))
            guard response.statusCode == Self.ok else { throw Failure.status(response.statusCode) }
            let read = try JSONDecoder().decode(Listing.self, from: data)
            state.withLock { state in
                if let held = state.listing, read.revision < held.revision { return }
                state.listing = read
            }
        } catch {
            let reason = String(describing: error)
            Self.logger.error("The tile server's routing list could not be read: \(reason, privacy: .public)")
        }
    }

    private static func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: TrailGraphSquareLibrary.requestTimeout)
        request.setValue(TileCache.userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    private static let ok = 200
    private static let noContent = 204
    private static let gone = 410
}

nonisolated extension RoutingGraphServer {
    /// A session of its own, with no cache: the provider keeps every region
    /// it reads, and a tile is a region.
    static func liveTransport() -> Transport {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = TrailGraphSquareLibrary.requestTimeout
        configuration.timeoutIntervalForResource = TrailGraphSquareLibrary.resourceTimeout
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        return { request in
            let (data, answer) = try await session.data(for: request)
            guard let response = answer as? HTTPURLResponse else { throw Failure.notHTTP }
            return (data, response)
        }
    }
}

extension TrailGraphSquareLibrary {
    /// The trail maker's graph for this launch, read from the tile server, or
    /// `nil` for a launch under test, UI tests included: no suite reaches the
    /// tile server, on the terms ``forThisLaunch()`` keeps for the public
    /// database.
    static func routingForThisLaunch() -> TrailGraphSquareLibrary? {
        guard !AppLaunchEnvironment.isRunningTests else { return nil }
        return TrailGraphSquareLibrary(
            database: RoutingGraphServer(
                server: VectorTileArchives.server,
                bundled: RoutingGraphServer.Listing.bundled
            ),
            layout: .routing,
            directory: nil
        )
    }
}
