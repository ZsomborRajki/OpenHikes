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
