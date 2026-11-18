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

    /// The basemap with extras beside it, from zoom 14.
    private var sourceWithExtras: VectorTileSource {
        var withExtras = source
        // swiftlint:disable:next force_unwrapping
        withExtras.extras = .init(archiveURL: URL(string: "https://tiles.example.invalid/extras")!, minimumZ: 14)
        return withExtras
    }

    private func makeClient(source: VectorTileSource? = nil) -> VectorTileClient {
        StubTileProtocol.reset()
        let now = clock
        return VectorTileClient(
            sources: ["osm": source ?? self.source],
            session: URLSession(configuration: StubTileProtocol.sessionConfiguration()),
            language: "en",
            now: { now.now }
        )
    }

    @Test("a provider with a source gets its tile drawn, from one request for it")
    func drawsATile() async throws {
        let client = makeClient()
        defer { StubTileProtocol.reset() }
        StubTileProtocol.alwaysRespond(with: .init(data: landTile))

        let png = try #require(await client.drawing(forKey: "osm/14/8800/5700").png)

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

        #expect(await client.drawing(forKey: key) == .fallBack)
        #expect(StubTileProtocol.requestCount == 0)
    }

    /// Past zoom 15 every tile is drawn from the zoom-15 tile around it, so
    /// the sixteen tiles of zoom 17 inside one need one request between them.
    @Test("deeper tiles ask for the archive tile around them, once between them")
    func deeperTilesShareTheirArchiveTile() async {
        let client = makeClient()
        defer { StubTileProtocol.reset() }
        StubTileProtocol.alwaysRespond(with: .init(data: landTile))

        let first = await client.drawing(forKey: "osm/17/70400/45600").png
        let sibling = await client.drawing(forKey: "osm/17/70403/45603").png

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

        #expect(await client.drawing(forKey: "osm/14/8800/5700") == .fallBack)
        #expect(client.isPaused)
        #expect(await client.drawing(forKey: "osm/14/8801/5700") == .fallBack)
        #expect(StubTileProtocol.requestCount == 1, "the next tile goes straight to the fallback")

        clock.advance(by: VectorTileClient.failurePause + .seconds(1))
        StubTileProtocol.alwaysRespond(with: .init(data: landTile))

        #expect(await client.drawing(forKey: "osm/14/8802/5700").png != nil)
        #expect(StubTileProtocol.requestCount == 2)
    }

    /// A server that says how long to stay away is taken at its word, as the
    /// raster servers are: the minute is a floor, not the wait.
    @Test("a server asking for longer with Retry-After is passed over until then")
    func retryAfterLengthensThePause() async {
        let client = makeClient()
        defer { StubTileProtocol.reset() }
        StubTileProtocol.alwaysRespond(with: .init(
            statusCode: RetryAfterHeader.tooManyRequests,
            data: Data("slow down".utf8),
            headers: [RetryAfterHeader.name: "600"]
        ))

        #expect(await client.drawing(forKey: "osm/14/8800/5700") == .fallBack)
        clock.advance(by: VectorTileClient.failurePause + .seconds(1))
        StubTileProtocol.alwaysRespond(with: .init(data: landTile))

        #expect(await client.drawing(forKey: "osm/14/8801/5700") == .fallBack)
        #expect(StubTileProtocol.requestCount == 1, "the server asked for ten minutes, not one")

        clock.advance(by: .seconds(600) - VectorTileClient.failurePause)

        #expect(await client.drawing(forKey: "osm/14/8802/5700").png != nil)
        #expect(StubTileProtocol.requestCount == 2)
    }

    /// A phone with no connection learns nothing of the server: the next tile
    /// asks it again, and the raster template is not asked in its place.
    @Test("a failure of the device's own connection pauses nothing and falls back to nothing", arguments: [
        URLError.Code.notConnectedToInternet,
        .networkConnectionLost,
        .dataNotAllowed,
    ])
    func offlineIsNotTheServers(code: URLError.Code) async {
        let client = makeClient()
        defer { StubTileProtocol.reset() }
        StubTileProtocol.alwaysRespond(with: .init(failure: URLError(code)))

        #expect(await client.drawing(forKey: "osm/14/8800/5700") == .offline)
        #expect(!client.isPaused)
        StubTileProtocol.alwaysRespond(with: .init(data: landTile))

        #expect(await client.drawing(forKey: "osm/14/8801/5700").png != nil)
        #expect(StubTileProtocol.requestCount == 2)
    }

    /// The tiles past zoom 15 inside an archive tile already fetched need no
    /// server, so a pause for another tile's failure does not reach them.
    @Test("a tile already held is drawn while the server is passed over")
    func keptTileOutlastsThePause() async {
        let client = makeClient()
        defer { StubTileProtocol.reset() }
        StubTileProtocol.alwaysRespond(with: .init(data: landTile))
        #expect(await client.drawing(forKey: "osm/17/70400/45600").png != nil)
        StubTileProtocol.alwaysRespond(with: .status(503))
        #expect(await client.drawing(forKey: "osm/15/17601/11400") == .fallBack)
        #expect(client.isPaused)

        #expect(await client.drawing(forKey: "osm/17/70403/45603").png != nil)
        #expect(StubTileProtocol.requestCount == 2, "drawn from the archive tile already held")
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

        #expect(await client.drawing(forKey: "osm/14/8800/5700") == .fallBack)
        #expect(!client.isPaused)
        #expect(await client.drawing(forKey: "osm/14/8801/5700") == .fallBack)
        #expect(StubTileProtocol.requestCount == 2)
    }

    // MARK: Extras

    @Test("the extras are asked for beside the basemap, and a deeper tile shares both")
    func extrasAreAskedFor() async {
        let client = makeClient(source: sourceWithExtras)
        defer { StubTileProtocol.reset() }
        StubTileProtocol.alwaysRespond(with: .init(data: landTile))

        #expect(await client.drawing(forKey: "osm/17/70400/45600").png != nil)
        #expect(await client.drawing(forKey: "osm/17/70403/45603").png != nil)

        #expect(Set(StubTileProtocol.requests.compactMap { $0.url?.path }) == [
            "/planet/15/17600/11400.mvt", "/extras/15/17600/11400.mvt",
        ])
        #expect(StubTileProtocol.requestCount == 2)
    }

    @Test("a tile wider than the extras' first zoom asks only the basemap")
    func extrasWaitForTheirZoom() async {
        let client = makeClient(source: sourceWithExtras)
        defer { StubTileProtocol.reset() }
        StubTileProtocol.alwaysRespond(with: .init(data: landTile))

        #expect(await client.drawing(forKey: "osm/13/4400/2850").png != nil)
        #expect(StubTileProtocol.requests.map { $0.url?.path } == ["/planet/13/4400/2850.mvt"])
    }

    /// The extras add to the map and are never its reason to fall back: where
    /// they have nothing, or their request fails, the basemap is drawn alone.
    @Test("extras the server does not have, or fails to give, leave the basemap drawn", arguments: [
        StubTileProtocol.Response(statusCode: 204),
        StubTileProtocol.Response.status(404),
        StubTileProtocol.Response.undecodable(),
    ])
    func missingExtrasLeaveTheBasemap(response: StubTileProtocol.Response) async {
        let client = makeClient(source: sourceWithExtras)
        defer { StubTileProtocol.reset() }
        let land = StubTileProtocol.Response(data: landTile)
        StubTileProtocol.respond { url in url.path.hasPrefix("/extras") ? response : land }

        #expect(await client.drawing(forKey: "osm/15/17600/11400").png != nil)
        #expect(!client.isPaused)
    }

    @Test("a failed request is the server's, unless the device's connection failed")
    func failedRequestOutcomes() {
        #expect(VectorTileClient.outcome(of: URLError(.notConnectedToInternet)) == .offline)
        #expect(VectorTileClient.outcome(of: URLError(.timedOut)) == .unavailable(pause: VectorTileClient.failurePause))
        #expect(
            VectorTileClient.outcome(of: URLError(.cannotConnectToHost))
                == .unavailable(pause: VectorTileClient.failurePause)
        )
    }

    @Test("a response is read as a tile, a missing tile, or a server to pass over")
    func outcomes() {
        let body = Data([1])
        #expect(VectorTileClient.outcome(status: 200, data: body) == .tile(body))
        #expect(VectorTileClient.outcome(status: 200, data: Data()) == .missing)
        #expect(VectorTileClient.outcome(status: 204, data: Data()) == .missing)
        #expect(VectorTileClient.outcome(status: 404, data: body) == .missing)
        #expect(VectorTileClient.outcome(status: 429, data: body) == .unavailable(pause: VectorTileClient.failurePause))
        #expect(VectorTileClient.outcome(status: 502, data: body) == .unavailable(pause: VectorTileClient.failurePause))
    }

    @Test("advice longer than the pause lengthens it, and shorter advice leaves it")
    func outcomeKeepsTheLongerPause() {
        let body = Data([1])
        let longer = VectorTileClient.failurePause * 10
        let shorter = VectorTileClient.failurePause / 10

        #expect(VectorTileClient.outcome(status: 429, data: body, retryAfter: longer) == .unavailable(pause: longer))
        #expect(
            VectorTileClient.outcome(status: 503, data: body, retryAfter: shorter)
                == .unavailable(pause: VectorTileClient.failurePause)
        )
        #expect(VectorTileClient.outcome(status: 404, data: body, retryAfter: longer) == .missing)
    }
}

nonisolated private extension VectorTileClient.Drawing {
    /// The drawn tile, if this is one.
    var png: Data? {
        guard case let .png(data) = self else { return nil }
        return data
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
