//
//  RoutingGraphServerTests.swift
//  OpenHikesTests
//
//  What the trail maker's graph on the tile server answers a tile with, read
//  as the public database's answers for a square are: which archive it asks,
//  what a tile, no tile, a retired archive and a failing server each mean,
//  and that a region read through it is the graph Overpass gives.
//
//  The server is a stub, for the reason the repository's *Deliberate test
//  seams* section gives.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import Synchronization
import Testing

@Suite("Routing graph server")
struct RoutingGraphServerTests {
    // MARK: - Fixtures

    static let server = URL(string: "https://tiles.example/")
    static let current = RoutingGraphServer.Listing.Archive(name: "routing-20261122-00", generation: 1, zoom: 12)
    static let next = RoutingGraphServer.Listing.Archive(name: "routing-20261129-00", generation: 1, zoom: 12)
    /// The region over `OverpassGraphFixture.alpineRoute`, which is its tile.
    static let region = TrailGraphRegion(zoom: 12, x: 2194, y: 1430)
    static let tile = TrailGraphSquare(x: 2194, y: 1430)
    static let tileName = "routing1_z12_2194_1430"

    static func tilePath(_ archive: RoutingGraphServer.Listing.Archive) -> String {
        "\(archive.name)/12/2194/1430.bin"
    }

    static func listing(revision: Int, _ archives: [RoutingGraphServer.Listing.Archive]) -> RoutingGraphServer.Listing {
        RoutingGraphServer.Listing(version: 1, revision: revision, routing: archives)
    }

    /// `OverpassGraphFixture.alpineRoute` as a tile holds it: way 10 with the
    /// hiking route it is part of, and not way 11, which is private.
    static let squareFile = TrailGraphSquareFile(ways: [TrailGraphSquareLibraryTests.localPath]).encoded()

    /// A clock a case moves by hand.
    final class Clock: Sendable {
        private let now = Mutex(Date(timeIntervalSince1970: 1_800_000_000))

        var read: @Sendable () -> Date { { self.now.withLock { $0 } } }

        func advance(by seconds: TimeInterval) { now.withLock { $0 += seconds } }
    }

    static func reader(
        _ tiles: StubTileServer,
        bundled: RoutingGraphServer.Listing?,
        clock: Clock = Clock()
    ) throws -> RoutingGraphServer {
        RoutingGraphServer(
            server: try #require(server),
            bundled: bundled,
            clock: clock.read,
            transport: tiles.transport
        )
    }

    // MARK: - A tile

    @Test("a tile is asked of the archive the server lists, and is the region's square")
    func aTileIsTheSquare() async throws {
        let tiles = StubTileServer([
            "manifest.json": [StubTileServer.manifest(revision: 9, routing: [Self.current])],
            Self.tilePath(Self.current): [.ok(Self.squareFile)],
        ])
        let reader = try Self.reader(tiles, bundled: nil)

        let fetch = try await reader.fetch(cellsNamed: [Self.tileName])

        #expect(fetch == TrailCellFetch(manifest: .complete, cells: [Self.tileName: .found(Self.squareFile)]))
        #expect(tiles.paths == ["manifest.json", Self.tilePath(Self.current)])
        #expect(tiles.requests.allSatisfy { $0.value(forHTTPHeaderField: "User-Agent") == TileCache.userAgent })
    }

    /// Every listed archive is the whole world, so a tile it does not hold
    /// is ground with no ways on it, which the library keeps as such.
    @Test("no tile is ground with no ways on it")
    func noTileIsEmptyGround() async throws {
        let tiles = StubTileServer([
            "manifest.json": [StubTileServer.manifest(revision: 9, routing: [Self.current])],
            Self.tilePath(Self.current): [.init(status: 204)],
        ])
        let reader = try Self.reader(tiles, bundled: nil)

        let fetch = try await reader.fetch(cellsNamed: [Self.tileName])

        #expect(fetch == TrailCellFetch(manifest: .complete, cells: [Self.tileName: .absent]))
    }

    @Test("a name that is not one of this generation's tiles is not asked for")
    func aNameNotATile() async throws {
        let tiles = StubTileServer(["manifest.json": [StubTileServer.manifest(revision: 9, routing: [Self.current])]])
        let reader = try Self.reader(tiles, bundled: nil)

        let fetch = try await reader.fetch(cellsNamed: ["graph1_z10_548_357"])

        #expect(fetch == TrailCellFetch(manifest: .complete, cells: ["graph1_z10_548_357": .failed]))
        #expect(tiles.paths == ["manifest.json"])
    }

    @Test("a server that cannot answer is a failure, not empty ground")
    func aFailingServerThrows() async throws {
        let tiles = StubTileServer([
            "manifest.json": [StubTileServer.manifest(revision: 9, routing: [Self.current])],
            Self.tilePath(Self.current): [.init(status: 503)],
        ])
        let reader = try Self.reader(tiles, bundled: nil)

        await #expect(throws: RoutingGraphServer.Failure.status(503)) {
            try await reader.fetch(cellsNamed: [Self.tileName])
        }
    }

    // MARK: - Which archive

    @Test("no archive this build reads leaves the region to Overpass and asks for no tile", arguments: [
        [],
        [RoutingGraphServer.Listing.Archive(name: "routing-20261122-00", generation: 2, zoom: 12)],
        [RoutingGraphServer.Listing.Archive(name: "routing-20261122-00", generation: 1, zoom: 10)],
        [RoutingGraphServer.Listing.Archive(name: "../manifest", generation: 1, zoom: 12)],
        [RoutingGraphServer.Listing.Archive(name: "planet-20261118", generation: 1, zoom: 12)],
    ])
    func noArchiveIsNoAnswer(routing: [RoutingGraphServer.Listing.Archive]) async throws {
        let tiles = StubTileServer(["manifest.json": [StubTileServer.manifest(revision: 9, routing: routing)]])
        let reader = try Self.reader(tiles, bundled: nil)

        let fetch = try await reader.fetch(cellsNamed: [Self.tileName])

        #expect(fetch == TrailCellFetch(manifest: .absent, cells: [:]))
        #expect(tiles.paths == ["manifest.json"])
    }

    /// What the server says to a build that reads it before the first
    /// routing archive is named, and what an older build's manifest is.
    @Test("a manifest from before the trail maker's archive names none")
    func aManifestWithNoRoutingList() async throws {
        let manifest = Data(#"{"version": 1, "revision": 8, "basemaps": [], "extras": []}"#.utf8)
        let tiles = StubTileServer(["manifest.json": [.ok(manifest)]])
        let reader = try Self.reader(tiles, bundled: nil)

        let fetch = try await reader.fetch(cellsNamed: [Self.tileName])

        #expect(fetch == TrailCellFetch(manifest: .absent, cells: [:]))
        #expect(tiles.paths == ["manifest.json"])
    }

    @Test("the first archive of the list that this build reads is the one asked")
    func theFirstReadArchive() async throws {
        let later = RoutingGraphServer.Listing.Archive(name: "routing-20261201-00", generation: 2, zoom: 12)
        let tiles = StubTileServer([
            "manifest.json": [StubTileServer.manifest(revision: 9, routing: [later, Self.current])],
            Self.tilePath(Self.current): [.init(status: 204)],
        ])
        let reader = try Self.reader(tiles, bundled: nil)

        _ = try await reader.fetch(cellsNamed: [Self.tileName])

        #expect(tiles.paths.last == Self.tilePath(Self.current))
    }

    @Test("a list that could not be read keeps the one the app bundles")
    func anUnreadListKeepsTheBundled() async throws {
        let tiles = StubTileServer([
            "manifest.json": [.init(status: 500)],
            Self.tilePath(Self.current): [.init(status: 204)],
        ])
        let reader = try Self.reader(tiles, bundled: Self.listing(revision: 9, [Self.current]))

        let fetch = try await reader.fetch(cellsNamed: [Self.tileName])

        #expect(fetch.manifest == .complete)
        #expect(tiles.paths == ["manifest.json", Self.tilePath(Self.current)])
    }

    @Test("a list older than the one held is not taken")
    func anOlderListIsNotTaken() async throws {
        let tiles = StubTileServer([
            "manifest.json": [StubTileServer.manifest(revision: 8, routing: [Self.current])],
            Self.tilePath(Self.next): [.init(status: 204)],
        ])
        let reader = try Self.reader(tiles, bundled: Self.listing(revision: 9, [Self.next]))

        _ = try await reader.fetch(cellsNamed: [Self.tileName])

        #expect(reader.archive == Self.next.name)
        #expect(tiles.paths.last == Self.tilePath(Self.next))
    }

    @Test("the list is read again an hour after it was read, and not before")
    func theListIsReadHourly() async throws {
        let tiles = StubTileServer([
            "manifest.json": [StubTileServer.manifest(revision: 9, routing: [Self.current])],
            Self.tilePath(Self.current): [.init(status: 204)],
        ])
        let clock = Clock()
        let reader = try Self.reader(tiles, bundled: nil, clock: clock)

        _ = try await reader.fetch(cellsNamed: [Self.tileName])
        clock.advance(by: RoutingGraphServer.readInterval - 1)
        _ = try await reader.fetch(cellsNamed: [Self.tileName])
        #expect(tiles.paths.filter { $0 == "manifest.json" }.count == 1)

        clock.advance(by: 1)
        _ = try await reader.fetch(cellsNamed: [Self.tileName])
        #expect(tiles.paths.filter { $0 == "manifest.json" }.count == 2)
    }

    // MARK: - A retired archive

    /// What a build out in the world meets once an archive it was told of is
    /// pruned: a 410, which sends it to the list for the archive after.
    @Test("a retired archive has the list read again, and the tile asked of the archive it names now")
    func aRetiredArchiveMoves() async throws {
        // Read a minute ago, when the list still named the archive now retired.
        let tiles = StubTileServer([
            "manifest.json": [StubTileServer.manifest(revision: 9, routing: [Self.current])],
            Self.tilePath(Self.current): [.init(status: 410)],
            Self.tilePath(Self.next): [.ok(Self.squareFile)],
        ])
        let clock = Clock()
        let reader = try Self.reader(tiles, bundled: Self.listing(revision: 9, [Self.current]), clock: clock)
        _ = try? await reader.fetch(cellsNamed: [Self.tileName])
        tiles.answer("manifest.json", with: [StubTileServer.manifest(revision: 10, routing: [Self.next, Self.current])])
        clock.advance(by: RoutingGraphServer.retiredReadInterval)

        let fetch = try await reader.fetch(cellsNamed: [Self.tileName])

        #expect(fetch == TrailCellFetch(manifest: .complete, cells: [Self.tileName: .found(Self.squareFile)]))
        #expect(reader.archive == Self.next.name)
        let asked = [Self.tilePath(Self.current), "manifest.json", Self.tilePath(Self.next)]
        #expect(Array(tiles.paths.suffix(3)) == asked)
    }

    /// A list read moments ago that still names the archive is not mended
    /// by asking again at once, and the region goes to Overpass meanwhile.
    @Test("a retired archive the list still names is no answer, and the list is not read again at once")
    func aRetiredArchiveStillListed() async throws {
        let tiles = StubTileServer([
            "manifest.json": [StubTileServer.manifest(revision: 9, routing: [Self.current])],
            Self.tilePath(Self.current): [.init(status: 410)],
        ])
        let reader = try Self.reader(tiles, bundled: nil)

        let fetch = try await reader.fetch(cellsNamed: [Self.tileName])

        #expect(fetch == TrailCellFetch(manifest: .unread, cells: [:]))
        #expect(tiles.paths == ["manifest.json", Self.tilePath(Self.current)])
    }

    // MARK: - Through the library

    /// The case everything rests on: a region the maker reads through the
    /// library from a tile sits in the provider's cache beside regions read
    /// from Overpass, merged at the nodes they share.
    @Test("a region read through the library is the graph Overpass gives for the same ways")
    func aRegionReadsAsOverpassDoes() async throws {
        let fromOverpass = try OverpassTrailGraphProvider.decodeGraph(from: Data(OverpassGraphFixture.alpineRoute.utf8))
        let tiles = StubTileServer([
            "manifest.json": [StubTileServer.manifest(revision: 9, routing: [Self.current])],
            Self.tilePath(Self.current): [.ok(Self.squareFile)],
        ])
        let reader = try Self.reader(tiles, bundled: nil)
        let library = TrailGraphSquareLibrary(database: reader, layout: .routing, directory: nil)

        let answer = await library.graph(for: Self.region)

        guard case .graph(let fromTile, _) = answer else {
            Issue.record("the archive gave no answer: \(answer)")
            return
        }
        #expect(fromTile == fromOverpass)
    }

    @Test("the bundled manifest names an archive of the trail maker's graph this build reads")
    func theBundledListing() throws {
        let listing = try #require(RoutingGraphServer.Listing.bundled)
        let name = try #require(listing.archive)
        #expect(RoutingGraphArchive.isArchiveName(name))
    }
}
