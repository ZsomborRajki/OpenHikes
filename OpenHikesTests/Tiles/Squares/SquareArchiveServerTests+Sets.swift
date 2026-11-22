//
//  SquareArchiveServerTests+Sets.swift
//  OpenHikesTests
//
//  The sets beside the trail graph's: each reads its own list of the
//  server's manifest and asks its own tiles, and a call of many squares, as
//  the day hikes' search makes, keeps what arrived when some did not.
//

import Foundation
@testable import OpenHikes
import Testing

extension SquareArchiveServerTests {
    static let trails = SquareArchiveServer.Listing.Archive(name: "trails-20261122-00", generation: 1, zoom: 11)
    static let laterTrails = SquareArchiveServer.Listing.Archive(name: "trails-20261129-00", generation: 1, zoom: 11)
    static let routes = SquareArchiveServer.Listing.Archive(name: "routes-20261122-00", generation: 1, zoom: 11)
    static let places = SquareArchiveServer.Listing.Archive(name: "places-20261122-00", generation: 1, zoom: 9)

    /// Every set listed, as the server's manifest lists them.
    static let everySet: [SquareArchive: [SquareArchiveServer.Listing.Archive]] = [
        .routing: [current],
        .trails: [trails],
        .routes: [routes],
        .places: [places],
    ]

    static let square = Data("a square".utf8)
    static let otherSquare = Data("another square".utf8)

    static func reader(
        _ set: SquareArchive,
        _ tiles: StubTileServer,
        bundled: SquareArchiveServer.Listing? = nil,
        clock: Clock = Clock()
    ) throws -> SquareArchiveServer {
        SquareArchiveServer(
            set: set,
            server: try #require(server),
            bundled: bundled,
            requestTimeout: TrailCellLibrary.requestTimeout,
            clock: clock.read,
            transport: tiles.transport
        )
    }

    @Test("each set asks its own archive for its own tiles", arguments: [
        (SquareArchive.trails, "trails1_550_796", "trails-20261122-00/11/796/550.bin"),
        (.places, "places1_137_188", "places-20261122-00/9/188/137.bin"),
        (.routes, "routes1_z14_550_796", "routes-20261122-00/11/796/550.bin"),
        (.routing, "routing1_z12_2194_1430", "routing-20261122-00/12/2194/1430.bin"),
    ])
    func eachSetItsOwnArchive(set: SquareArchive, name: String, path: String) async throws {
        let tiles = StubTileServer([
            "manifest.json": [StubTileServer.manifest(revision: 11, Self.everySet)],
            path: [.ok(Self.square)],
        ])
        let reader = try Self.reader(set, tiles)

        let fetch = try await reader.fetch(cellsNamed: [name])

        #expect(fetch == TrailCellFetch(manifest: .complete, cells: [name: .found(Self.square)]))
        #expect(tiles.paths == ["manifest.json", path])
    }

    /// The server's manifest names the routing archive alone until the
    /// other sets go up: their libraries go on as before there were squares.
    @Test("a set the manifest has no list for has no archive, whatever the other sets have")
    func aSetWithNoList() async throws {
        let tiles = StubTileServer(["manifest.json": [StubTileServer.manifest(revision: 10, routing: [Self.current])]])
        let reader = try Self.reader(.trails, tiles)

        let fetch = try await reader.fetch(cellsNamed: ["trails1_550_796"])

        #expect(fetch == TrailCellFetch(manifest: .absent, cells: [:]))
        #expect(tiles.paths == ["manifest.json"])
    }

    @Test("an archive listed under another set's list is not read")
    func anotherSetsArchive() async throws {
        let tiles = StubTileServer(["manifest.json": [StubTileServer.manifest(revision: 11, [.trails: [Self.places]])]])
        let reader = try Self.reader(.trails, tiles)

        let fetch = try await reader.fetch(cellsNamed: ["trails1_550_796"])

        #expect(fetch == TrailCellFetch(manifest: .absent, cells: [:]))
    }

    /// A wide search names dozens of squares in one call, and the server
    /// answers each in its own request: one that fails is that square's
    /// failure, and the squares that arrived are the library's to keep.
    @Test("a square that fails among others that arrive is that square's failure alone")
    func oneSquareFails() async throws {
        let tiles = StubTileServer([
            "manifest.json": [StubTileServer.manifest(revision: 11, Self.everySet)],
            "trails-20261122-00/11/796/550.bin": [.ok(Self.square)],
            "trails-20261122-00/11/797/550.bin": [.init(status: 503)],
            "trails-20261122-00/11/798/550.bin": [.init(status: 204)],
        ])
        let reader = try Self.reader(.trails, tiles)

        let fetch = try await reader.fetch(cellsNamed: ["trails1_550_796", "trails1_550_797", "trails1_550_798"])

        #expect(fetch == TrailCellFetch(manifest: .complete, cells: [
            "trails1_550_796": .found(Self.square),
            "trails1_550_797": .failed,
            "trails1_550_798": .absent,
        ]))
    }

    @Test("a call none of whose squares could be asked fails as a whole")
    func everySquareFails() async throws {
        let tiles = StubTileServer([
            "manifest.json": [StubTileServer.manifest(revision: 11, Self.everySet)],
            "trails-20261122-00/11/796/550.bin": [.init(status: 503)],
            "trails-20261122-00/11/797/550.bin": [.init(status: 502)],
        ])
        let reader = try Self.reader(.trails, tiles)

        await #expect(throws: SquareArchiveServer.Failure.self) {
            try await reader.fetch(cellsNamed: ["trails1_550_796", "trails1_550_797"])
        }
    }

    @Test("every square of a call is asked, more of them than are asked at once")
    func moreSquaresThanAtOnce() async throws {
        let columns = 700..<(700 + SquareArchiveServer.concurrentRequests * 3)
        var answers: [String: [StubTileServer.Answer]] = [
            "manifest.json": [StubTileServer.manifest(revision: 11, Self.everySet)],
        ]
        for column in columns {
            answers["trails-20261122-00/11/\(column)/550.bin"] = [.ok(Data("\(column)".utf8))]
        }
        let reader = try Self.reader(.trails, StubTileServer(answers))

        let fetch = try await reader.fetch(cellsNamed: columns.map { "trails1_550_\($0)" })

        #expect(fetch.manifest == .complete)
        #expect(fetch.cells.count == columns.count)
        for column in columns {
            #expect(fetch.cells["trails1_550_\(column)"] == .found(Data("\(column)".utf8)))
        }
    }

    @Test("the squares of a call an archive retired are asked of the one the list names now")
    func aRetiredArchiveMidCall() async throws {
        // Read a minute ago, when the list still named the archive now retired.
        let names = ["trails1_550_796", "trails1_550_797"]
        let tiles = StubTileServer([
            "manifest.json": [StubTileServer.manifest(revision: 11, Self.everySet)],
            "trails-20261122-00/11/796/550.bin": [.init(status: 410)],
            "trails-20261122-00/11/797/550.bin": [.init(status: 410)],
            "trails-20261129-00/11/796/550.bin": [.ok(Self.square)],
            "trails-20261129-00/11/797/550.bin": [.ok(Self.otherSquare)],
        ])
        let clock = Clock()
        let reader = try Self.reader(.trails, tiles, clock: clock)
        _ = try? await reader.fetch(cellsNamed: names)
        tiles.answer("manifest.json", with: [StubTileServer.manifest(revision: 12, [.trails: [Self.laterTrails]])])
        clock.advance(by: SquareArchiveServer.retiredReadInterval)

        let fetch = try await reader.fetch(cellsNamed: names)

        #expect(fetch == TrailCellFetch(manifest: .complete, cells: [
            names[0]: .found(Self.square),
            names[1]: .found(Self.otherSquare),
        ]))
        #expect(tiles.paths.suffix(3).first == "manifest.json")
        #expect(tiles.paths.suffix(2).allSatisfy { $0.hasPrefix("trails-20261129-00/") })
    }

    /// A route filed under A in the old build and under B in the new one is
    /// in neither if A comes from the old archive and B from the new.
    @Test("a call's squares are all one archive's: a retired one has every square asked again of the next")
    func oneArchiveACall() async throws {
        let names = ["trails1_550_796", "trails1_550_797"]
        let tiles = StubTileServer([
            "manifest.json": [StubTileServer.manifest(revision: 11, Self.everySet)],
            "trails-20261122-00/11/796/550.bin": [.ok(Self.otherSquare)],
            "trails-20261122-00/11/797/550.bin": [.init(status: 410)],
            "trails-20261129-00/11/796/550.bin": [.ok(Self.square)],
            "trails-20261129-00/11/797/550.bin": [.ok(Self.otherSquare)],
        ])
        let clock = Clock()
        let reader = try Self.reader(.trails, tiles, clock: clock)
        _ = try? await reader.fetch(cellsNamed: names)
        tiles.answer("manifest.json", with: [StubTileServer.manifest(revision: 12, [.trails: [Self.laterTrails]])])
        clock.advance(by: SquareArchiveServer.retiredReadInterval)

        let fetch = try await reader.fetch(cellsNamed: names)

        #expect(fetch == TrailCellFetch(manifest: .complete, cells: [
            names[0]: .found(Self.square),
            names[1]: .found(Self.otherSquare),
        ]))
    }

    /// A deadline that a suite ends itself: once the held request is out.
    static func deadline(when held: HeldRequest) -> @Sendable (TimeInterval) async -> Void {
        { _ in await held.arrived() }
    }

    static func reader(
        _ tiles: StubTileServer,
        holding held: HeldRequest,
        callTimeout: TimeInterval
    ) throws -> SquareArchiveServer {
        SquareArchiveServer(
            set: .trails,
            server: try #require(server),
            bundled: nil,
            requestTimeout: TrailCellLibrary.requestTimeout,
            callTimeout: callTimeout,
            waitOut: deadline(when: held),
            transport: tiles.transport(holding: held)
        )
    }

    /// A tile server that stops answering would otherwise hold a search for
    /// a request's timeout a wave, while the hiker waits for Overpass.
    @Test("a call that runs out of time keeps the squares that arrived, and fails the rest", .timeLimit(.minutes(1)))
    func aCallRunsOutOfTime() async throws {
        let held = HeldRequest("trails-20261122-00/11/797/550.bin")
        let tiles = StubTileServer([
            "manifest.json": [StubTileServer.manifest(revision: 11, Self.everySet)],
            "trails-20261122-00/11/796/550.bin": [.ok(Self.square)],
            "trails-20261122-00/11/797/550.bin": [.ok(Self.otherSquare)],
        ])
        let reader = try Self.reader(tiles, holding: held, callTimeout: TrailCellLibrary.resourceTimeout)

        let fetch = try await reader.fetch(cellsNamed: ["trails1_550_796", "trails1_550_797"])

        #expect(fetch == TrailCellFetch(manifest: .complete, cells: [
            "trails1_550_796": .found(Self.square),
            "trails1_550_797": .failed,
        ]))
    }

    @Test("a call none of whose squares arrives in time fails as a whole", .timeLimit(.minutes(1)))
    func nothingArrivesInTime() async throws {
        let held = HeldRequest("trails-20261122-00/11/796/550.bin")
        let tiles = StubTileServer([
            "manifest.json": [StubTileServer.manifest(revision: 11, Self.everySet)],
            "trails-20261122-00/11/796/550.bin": [.ok(Self.square)],
        ])
        let reader = try Self.reader(tiles, holding: held, callTimeout: TrailCellLibrary.resourceTimeout)

        await #expect(throws: SquareArchiveServer.Failure.timedOut) {
            try await reader.fetch(cellsNamed: ["trails1_550_796"])
        }
    }

    @Test("a launch's reader holds each call to the library's limit for a whole request")
    func theLiveCallTimeout() {
        let server = SquareArchiveServer.live(.trails, requestTimeout: 15, resourceTimeout: 30)
        #expect(server.callTimeout == 30)
    }

    @Test("the bundled manifest names an archive of every set this build reads", arguments: SquareArchive.allCases)
    func theBundledListingNamesEverySet(set: SquareArchive) throws {
        let listing = try #require(SquareArchiveServer.Listing.bundled)
        let name = try #require(listing.archive(of: set))
        #expect(set.isArchiveName(name))
    }

    @Test("a manifest is written with each set's list under its own name, and read back the same")
    func aListingRoundTrips() throws {
        let listing = SquareArchiveServer.Listing(version: 1, revision: 11, archives: Self.everySet)
        let data = try JSONEncoder().encode(listing)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(Set(object.keys) == ["version", "revision", "routing", "trails", "routes", "places"])
        #expect(try JSONDecoder().decode(SquareArchiveServer.Listing.self, from: data) == listing)
    }
}
