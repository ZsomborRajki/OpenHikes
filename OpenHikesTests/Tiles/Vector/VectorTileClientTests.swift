//
//  VectorTileClientTests.swift
//  OpenHikesTests
//
//  The client between a cache key and a drawn tile, with the tile server
//  replaced by `StubTileProtocol` and the clock by one the test moves: which
//  keys it answers, what it asks the server for, and when it gives up on the
//  server for a while. Serialized because the stub's script is process-wide.
//

import Foundation
@testable import OpenHikes
import Synchronization
import Testing
import UIKit

@Suite("Vector tile client", .serialized)
struct VectorTileClientTests {
    // swiftlint:disable:next force_unwrapping
    private let source = VectorTileSource(archiveURL: URL(string: "https://tiles.example.invalid/planet")!, maximumZ: 15)
    private let clock = SteppingClock()

    private var landTile: Data {
        VectorTileFixture.data([
            .init(name: "earth", features: [
                .init(
                    type: .polygon,
                    properties: ["kind": .string("earth")],
                    geometry: VectorTileFixture.rectangle(x: 0...VectorTileFixture.grid, y: 0...VectorTileFixture.grid)
                ),
            ]),
        ])
    }

    private func makeClient() -> VectorTileClient {
        StubTileProtocol.reset()
        let now = clock
        return VectorTileClient(
            sources: ["osm": source],
            session: URLSession(configuration: StubTileProtocol.sessionConfiguration()),
            now: { now.now }
        )
    }

    @Test("a provider with a source gets its tile drawn, from one request for it")
    func drawsATile() async throws {
        let client = makeClient()
        defer { StubTileProtocol.reset() }
        StubTileProtocol.alwaysRespond(with: .init(data: landTile))

        let png = try #require(await client.pngData(forKey: "osm/14/8800/5700"))

        #expect(TileImage(data: png) != nil)
        #expect(StubTileProtocol.requests.map { $0.url?.path } == ["/planet/14/8800/5700.mvt"])
        #expect(StubTileProtocol.requests.first?.timeoutInterval == VectorTileClient.requestTimeout)
    }

    @Test("a provider without a source, or a key of another shape, asks nothing", arguments: [
        "stadia_outdoors/14/8800/5700",
        "osm/14/8800",
        "not a key",
    ])
    func othersAreLeftAlone(key: String) async {
        let client = makeClient()
        defer { StubTileProtocol.reset() }
        StubTileProtocol.alwaysRespond(with: .init(data: landTile))

        #expect(await client.pngData(forKey: key) == nil)
        #expect(StubTileProtocol.requestCount == 0)
    }

    /// Past zoom 15 every tile is drawn from the zoom-15 tile around it, so
    /// the sixteen tiles of zoom 17 inside one need one request between them.
    @Test("deeper tiles ask for the archive tile around them, once between them")
    func deeperTilesShareTheirArchiveTile() async {
        let client = makeClient()
        defer { StubTileProtocol.reset() }
        StubTileProtocol.alwaysRespond(with: .init(data: landTile))

        let first = await client.pngData(forKey: "osm/17/70400/45600")
        let sibling = await client.pngData(forKey: "osm/17/70403/45603")

        #expect(first != nil)
        #expect(sibling != nil)
        #expect(StubTileProtocol.requests.map { $0.url?.path } == ["/planet/15/17600/11400.mvt"])
    }

    @Test("a failing server is passed over for a while, then asked again", arguments: [
        StubTileProtocol.Response.status(503),
        StubTileProtocol.Response.status(500),
        StubTileProtocol.Response.status(429),
        StubTileProtocol.Response(failure: URLError(.timedOut)),
    ])
    func failurePausesTheServer(response: StubTileProtocol.Response) async {
        let client = makeClient()
        defer { StubTileProtocol.reset() }
        StubTileProtocol.alwaysRespond(with: response)

        #expect(await client.pngData(forKey: "osm/14/8800/5700") == nil)
        #expect(client.isPaused)
        #expect(await client.pngData(forKey: "osm/14/8801/5700") == nil)
        #expect(StubTileProtocol.requestCount == 1, "the next tile goes straight to the fallback")

        clock.advance(by: VectorTileClient.failurePause + .seconds(1))
        StubTileProtocol.alwaysRespond(with: .init(data: landTile))

        #expect(await client.pngData(forKey: "osm/14/8802/5700") != nil)
        #expect(StubTileProtocol.requestCount == 2)
    }

    /// A tile the archive does not have, or cannot be read, is that tile's
    /// problem. The fallback draws it, and the server is still asked for the
    /// next one.
    @Test("a missing or unreadable tile falls back without pausing the server", arguments: [
        StubTileProtocol.Response.status(404),
        StubTileProtocol.Response(statusCode: 204),
        StubTileProtocol.Response.undecodable(),
    ])
    func missingTileKeepsTheServer(response: StubTileProtocol.Response) async {
        let client = makeClient()
        defer { StubTileProtocol.reset() }
        StubTileProtocol.alwaysRespond(with: response)

        #expect(await client.pngData(forKey: "osm/14/8800/5700") == nil)
        #expect(!client.isPaused)
        #expect(await client.pngData(forKey: "osm/14/8801/5700") == nil)
        #expect(StubTileProtocol.requestCount == 2)
    }

    @Test("a response is read as a tile, a missing tile, or a server to pass over")
    func outcomes() {
        let body = Data([1])
        #expect(VectorTileClient.outcome(status: 200, data: body) == .tile(body))
        #expect(VectorTileClient.outcome(status: 200, data: Data()) == .missing)
        #expect(VectorTileClient.outcome(status: 204, data: Data()) == .missing)
        #expect(VectorTileClient.outcome(status: 404, data: body) == .missing)
        #expect(VectorTileClient.outcome(status: 429, data: body) == .unavailable)
        #expect(VectorTileClient.outcome(status: 502, data: body) == .unavailable)
    }
}

/// A clock that moves only when the test says.
nonisolated private final class SteppingClock: Sendable {
    private let instant = Mutex(ContinuousClock.now)

    var now: ContinuousClock.Instant { instant.withLock { $0 } }

    func advance(by duration: Duration) {
        instant.withLock { $0 += duration }
    }
}
