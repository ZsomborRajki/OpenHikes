//
//  VectorTileFallbackTests.swift
//  OpenHikesTests
//
//  `TileCache` with a provider drawn from vector tiles: the drawn tile is what
//  the map gets and what is filed, and wherever the tile server cannot answer
//  the provider's raster template does, as it did before the server existed.
//  The two servers are told apart by host in `StubTileProtocol`'s script,
//  which is process-wide, so the suite is serialized.
//

import CoreGraphics
import Foundation
@testable import OpenHikes
import Synchronization
import Testing
import UIKit

@Suite("Vector tile fallback", .serialized)
struct VectorTileFallbackTests {
    private let key = "osm/14/8800/5700"
    private let vectorHost = "vector.example.invalid"
    // swiftlint:disable force_unwrapping
    private let rasterURL = URL(string: "https://raster.example.invalid/14/8800/5700.png")!
    private var sources: [String: VectorTileSource] {
        ["osm": VectorTileSource(archiveURL: URL(string: "https://\(vectorHost)/planet")!, maximumZ: 15)]
    }
    /// The basemap with extras beside it, from the zoom of ``key``.
    private var sourcesWithExtras: [String: VectorTileSource] {
        var source = VectorTileSource(archiveURL: URL(string: "https://\(vectorHost)/planet")!, maximumZ: 15)
        source.extras = .init(archiveURL: URL(string: "https://\(vectorHost)/extras")!, minimumZ: 14)
        return ["osm": source]
    }
    // swiftlint:enable force_unwrapping

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

    /// The vector server answers with `vector`, and the raster template with
    /// a raster tile.
    private func script(vector: StubTileProtocol.Response) {
        let host = vectorHost
        StubTileProtocol.respond { url in
            url.host() == host ? vector : .tile()
        }
    }

    /// The vector server answers its basemap with `vector()` and its extras
    /// with `extras()`, and the raster template with `raster`.
    private func respond(
        vector: @escaping @Sendable () -> StubTileProtocol.Response,
        extras: @escaping @Sendable () -> StubTileProtocol.Response = { .status(404) },
        raster: StubTileProtocol.Response = .tile()
    ) {
        let host = vectorHost
        StubTileProtocol.respond { url in
            guard url.host() == host else { return raster }
            return url.path.hasPrefix("/extras") ? extras() : vector()
        }
    }

    private var hosts: [String?] { StubTileProtocol.requests.map { $0.url?.host() } }

    @Test("a tile the server answers is drawn, filed, and costs no raster request")
    func servedTileIsDrawn() async throws {
        let stub = StubbedTileCache(vectorSources: sources)
        defer { stub.tearDown() }
        script(vector: .init(data: landTile))

        let image = try #require(await stub.cache.loadTile(forKey: key, url: rasterURL))

        #expect(image.cgImage?.width == VectorTileRasterizer.pixelSize, "the drawn picture, not the raster tile")
        #expect(hosts == [vectorHost])
        #expect(stub.isBrowsed(key), "filed in the browsing tier as any fetched tile is")
    }

    @Test("a server that fails hands the tile to the raster template, and the next one too")
    func failingServerFallsBack() async throws {
        let stub = StubbedTileCache(vectorSources: sources)
        defer { stub.tearDown() }
        script(vector: .status(503))

        let image = try #require(await stub.cache.loadTile(forKey: key, url: rasterURL))
        _ = await stub.cache.loadTile(forKey: "osm/14/8801/5700", url: rasterURL)

        #expect(image.cgImage?.width != VectorTileRasterizer.pixelSize, "the raster tile, not a drawn one")
        #expect(
            hosts == [vectorHost, rasterURL.host(), rasterURL.host()],
            "the second tile does not wait on the server"
        )
        #expect(stub.isBrowsed(key))
    }

    /// The raster template's tile would replace the hiker's coverage for a
    /// week, in another look. The saved copy is drawn until the server can
    /// draw it again, and stays due until then.
    @Test("a saved tile past its age stays the tile while the server fails, and the raster template is not asked")
    func savedTileOutlastsAFailingServer() async throws {
        let stub = StubbedTileCache(vectorSources: sources)
        defer { stub.tearDown() }
        script(vector: .status(503))
        let file = stub.savedFile(for: key)
        try stub.place(in: file, agedByDays: 8)
        let storedAt = { try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date }
        let placedAt = try storedAt()

        #expect(await stub.cache.loadTile(forKey: key, url: rasterURL) != nil, "the saved copy")
        #expect(hosts == [vectorHost])
        #expect(try storedAt() == placedAt, "not written over")
        #expect(stub.cache.freshDiskImage(forKey: key) == nil, "still due")
    }

    /// The connection that failed the tile server would fail the raster
    /// template too, and a raster tile that came back would be filed for a
    /// week among drawn ones.
    @Test("a device without a connection does not ask the raster template")
    func offlineDeviceDoesNotFallBack() async {
        let stub = StubbedTileCache(vectorSources: sources)
        defer { stub.tearDown() }
        script(vector: .init(failure: URLError(.notConnectedToInternet)))

        #expect(await stub.cache.loadTile(forKey: key, url: rasterURL) == nil)
        #expect(hosts == [vectorHost])
        #expect(!stub.isBrowsed(key))
    }

    /// A lost connection can be the server's doing: one that drops every
    /// connection is failing, and the raster template draws its tile.
    @Test("a connection lost twice hands the tile to the raster template")
    func lostConnectionFallsBack() async throws {
        let stub = StubbedTileCache(vectorSources: sources)
        defer { stub.tearDown() }
        script(vector: .init(failure: URLError(.networkConnectionLost)))

        let image = try #require(await stub.cache.loadTile(forKey: key, url: rasterURL))

        #expect(image.cgImage?.width != VectorTileRasterizer.pixelSize, "the raster tile, not a drawn one")
        #expect(hosts == [vectorHost, vectorHost, rasterURL.host()], "asked again once, then handed over")
        #expect(stub.isBrowsed(key))
    }

    @Test("a tile the archive does not have falls back to the raster template")
    func missingTileFallsBack() async throws {
        let stub = StubbedTileCache(vectorSources: sources)
        defer { stub.tearDown() }
        script(vector: .status(404))

        _ = try #require(await stub.cache.loadTile(forKey: key, url: rasterURL))

        #expect(hosts == [vectorHost, rasterURL.host()])
    }

    @Test("a provider without a vector source fetches its raster tile alone")
    func rasterProviderIsUnchanged() async throws {
        let stub = StubbedTileCache(vectorSources: sources)
        defer { stub.tearDown() }
        script(vector: .init(data: landTile))

        _ = try #require(await stub.cache.loadTile(forKey: "stadia_outdoors/14/8800/5700", url: rasterURL))

        #expect(hosts == [rasterURL.host()])
    }
}

// MARK: Drawn without the extras

extension VectorTileFallbackTests {
    /// The extras failing leave the basemap drawn, and that drawing is not
    /// the tile: filed, it would stand for a week without the gates and car
    /// parks an outage of a minute kept from it.
    @Test("a tile drawn without the extras the server failed to give is shown, and filed nowhere", arguments: [
        StubTileProtocol.Response.status(503),
        StubTileProtocol.Response.undecodable(),
    ])
    func provisionalTileIsNotFiled(extras: StubTileProtocol.Response) async throws {
        let stub = StubbedTileCache(vectorSources: sourcesWithExtras)
        defer { stub.tearDown() }
        let land = StubTileProtocol.Response(data: landTile)
        respond(vector: { land }, extras: { extras })

        #expect(await stub.cache.saveTileDurably(forKey: key, url: rasterURL) == false, "a download saves nothing")
        #expect(hosts == [vectorHost, vectorHost], "precondition: the download asked for both")
        #expect(!stub.isSaved(key))

        let image = try #require(await stub.cache.loadTile(forKey: key, url: rasterURL))

        #expect(image.cgImage?.width == VectorTileRasterizer.pixelSize, "the map draws the basemap")
        #expect(stub.cache.memoryImage(forKey: key) != nil)
        #expect(!stub.isBrowsed(key), "and keeps it on no disk")
        #expect(!hosts.contains(rasterURL.host()), "nor falls back for it")
    }

    @Test("a tile drawn without its extras is drawn again, with them, once its memory entry lapses")
    func provisionalTileIsDrawnAgain() async throws {
        let stub = StubbedTileCache(vectorSources: sourcesWithExtras)
        defer { stub.tearDown() }
        let land = StubTileProtocol.Response(data: landTile)
        let recovered = Flag()
        respond(vector: { land }, extras: { recovered.isSet ? land : .status(403) })

        _ = try #require(await stub.cache.loadTile(forKey: key, url: rasterURL))
        #expect(!stub.isBrowsed(key), "precondition: drawn without its extras")
        recovered.set()
        let lapsed = Date().addingTimeInterval(TileCache.staleCoverageRecheckInterval + 1)
        #expect(stub.cache.memoryImage(forKey: key, referenceDate: lapsed) == nil, "it answers for the recheck alone")

        _ = try #require(await stub.cache.loadTile(forKey: key, url: rasterURL))

        #expect(stub.isBrowsed(key), "drawn whole, and filed")
        #expect(!hosts.contains(rasterURL.host()))
    }
}

// MARK: A raster server's Retry-After

extension VectorTileFallbackTests {
    private var rateLimited: StubTileProtocol.Response {
        .init(
            statusCode: RetryAfterHeader.tooManyRequests,
            data: Data("slow down".utf8),
            headers: [RetryAfterHeader.name: "600"]
        )
    }

    /// A `Retry-After` from the raster template is that server's answer. The
    /// tile server ahead of it is still asked, and a tile it draws again is
    /// drawn at once, where the deadline used to leave it blank for its ten
    /// minutes. The map backs off on its own delays meanwhile.
    @Test("a raster server's Retry-After holds back the raster server, and not the tile server")
    func rasterRetryAfterLeavesTheTileServerAsked() async throws {
        let stub = StubbedTileCache(vectorSources: sources)
        defer { stub.tearDown() }
        let land = StubTileProtocol.Response(data: landTile)
        let recovered = Flag()
        respond(vector: { recovered.isSet ? land : .undecodable() }, raster: rateLimited)

        #expect(await stub.cache.loadTile(forKey: key, url: rasterURL) == nil)
        #expect(hosts == [vectorHost, rasterURL.host()], "precondition: the fallback was refused")
        #expect(stub.cache.retryDeadline(for: rasterURL) != nil)
        #expect(stub.cache.retryDeadline(forKey: key, url: rasterURL) == nil, "the map backs off on its own delays")

        #expect(await stub.cache.loadTile(forKey: key, url: rasterURL) == nil)
        #expect(hosts == [vectorHost, rasterURL.host(), vectorHost], "the tile server is asked, the raster one is not")

        recovered.set()
        let image = try #require(await stub.cache.loadTile(forKey: key, url: rasterURL))

        #expect(image.cgImage?.width == VectorTileRasterizer.pixelSize)
        #expect(hosts == [vectorHost, rasterURL.host(), vectorHost, vectorHost])
    }

    /// The comparison style draws the raster tiles alone, from the very URL
    /// the vector style falls back to, so a deadline one of them was given
    /// holds for both.
    @Test("the comparison style waits out a deadline the fallback was given")
    func comparisonStyleHonorsTheFallbacksDeadline() async {
        let stub = StubbedTileCache(vectorSources: sources)
        defer { stub.tearDown() }
        let comparisonKey = "osm_raster/14/8800/5700"
        respond(vector: { .status(503) }, raster: rateLimited)

        #expect(await stub.cache.loadTile(forKey: key, url: rasterURL) == nil)
        #expect(await stub.cache.loadTile(forKey: comparisonKey, url: rasterURL) == nil)

        #expect(hosts == [vectorHost, rasterURL.host()], "one request to the raster server between the two")
        #expect(stub.cache.retryDeadline(forKey: comparisonKey, url: rasterURL) != nil, "and its map backs off to it")
    }
}

/// A switch the test flips while the stub, which reads it under its own
/// lock, answers.
nonisolated private final class Flag: Sendable {
    private let state = Mutex(false)

    var isSet: Bool { state.withLock { $0 } }

    func set() {
        state.withLock { $0 = true }
    }
}
