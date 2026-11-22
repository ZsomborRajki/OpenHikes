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

    /// A clock a case moves by hand, and can wait to be read: the reader
    /// reads it first thing whenever it considers the list.
    final class Clock: Sendable {
        private let now = Mutex(Date(timeIntervalSince1970: 1_800_000_000))
        private let readings: AsyncStream<Void>
        private let reading: AsyncStream<Void>.Continuation

        init() {
            (readings, reading) = AsyncStream.makeStream(of: Void.self)
        }

        var read: @Sendable () -> Date {
            {
                self.reading.yield()
                return self.now.withLock { $0 }
            }
        }

        func advance(by seconds: TimeInterval) { now.withLock { $0 += seconds } }

        /// Returns once the clock has been read `count` times since it was
        /// made.
        func waitForReads(_ count: Int) async {
            var seen = 0
            for await _ in readings {
                seen += 1
                if seen >= count { break }
            }
        }
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
    /// is ground with no ways on it, which the library keeps as such. The
    /// server says so with a 204, and an empty 200 is how a cache in front
    /// of it might, as the map reads one.
    @Test("no tile is ground with no ways on it", arguments: [
        StubTileServer.Answer(status: 204),
        StubTileServer.Answer.ok(Data()),
    ])
    func noTileIsEmptyGround(answer: StubTileServer.Answer) async throws {
        let tiles = StubTileServer([
            "manifest.json": [StubTileServer.manifest(revision: 9, routing: [Self.current])],
            Self.tilePath(Self.current): [answer],
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

    // MARK: - While the list is read

    /// A build whose bundled archive is pruned, at its first read of the
    /// list: the server lists the next archive, and the bundled one is gone.
    static func prunedSinceBuilt(clock: Clock, held: HeldRequest) throws -> (StubTileServer, RoutingGraphServer) {
        let tiles = StubTileServer([
            "manifest.json": [StubTileServer.manifest(revision: 10, routing: [Self.next])],
            Self.tilePath(Self.current): [.init(status: 410)],
            Self.tilePath(Self.next): [.ok(Self.squareFile)],
        ])
        let reader = RoutingGraphServer(
            server: try #require(server),
            bundled: Self.listing(revision: 9, [Self.current]),
            clock: clock.read,
            transport: tiles.transport(holding: held)
        )
        return (tiles, reader)
    }

    /// The maker closed while its first region waited on the list. Ended
    /// with that region's request, the read would count as made, and every
    /// tile for the next minute would be asked of the pruned archive and
    /// left to Overpass. And the region does not wait out the read: it ends
    /// while the server is still holding the list, or this case runs out of
    /// time.
    @Test(
        "a region given up on while the list is read stops at once, and does not end the read",
        .timeLimit(.minutes(1))
    )
    func aRegionGivenUpOnLeavesTheRead() async throws {
        let held = HeldRequest("manifest.json")
        let (tiles, reader) = try Self.prunedSinceBuilt(clock: Clock(), held: held)
        let givenUp = Task { try await reader.fetch(cellsNamed: [Self.tileName]) }
        await held.arrived()
        givenUp.cancel()
        await #expect(throws: CancellationError.self) { try await givenUp.value }
        held.release()

        let fetch = try await reader.fetch(cellsNamed: [Self.tileName])

        #expect(fetch == TrailCellFetch(manifest: .complete, cells: [Self.tileName: .found(Self.squareFile)]))
        #expect(tiles.paths.filter { $0 == "manifest.json" }.count == 1)
        #expect(!tiles.paths.contains(Self.tilePath(Self.current)))
    }

    @Test("a tile asked for while the list is read waits on that read, rather than asking the archive held before it")
    func aTileWaitsOnTheRead() async throws {
        let clock = Clock()
        let held = HeldRequest("manifest.json")
        let (tiles, reader) = try Self.prunedSinceBuilt(clock: clock, held: held)
        let first = Task { try await reader.fetch(cellsNamed: [Self.tileName]) }
        await held.arrived()
        let second = Task { try await reader.fetch(cellsNamed: [Self.tileName]) }
        // The second has come to the list, as the first did.
        await clock.waitForReads(2)
        held.release()

        let found = TrailCellFetch(manifest: .complete, cells: [Self.tileName: .found(Self.squareFile)])
        #expect(try await first.value == found)
        #expect(try await second.value == found)
        #expect(tiles.paths.filter { $0 == "manifest.json" }.count == 1)
        #expect(!tiles.paths.contains(Self.tilePath(Self.current)))
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
