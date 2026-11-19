//
//  VectorTileRetirementTests.swift
//  OpenHikesTests
//
//  `TileCache` drawing from archives the tile server no longer has: a 410
//  has the manifest read again and the tile drawn from what it names now,
//  rather than from the raster template, and a tile drawn before the move
//  is drawn again. The server answers 410 for every archive the test has
//  not made live, through `StubTileProtocol`'s script, which is
//  process-wide, so the suite is serialized.
//

import CoreGraphics
import Foundation
@testable import OpenHikes
import Testing
import UIKit

@Suite("Vector tiles: a retired archive", .serialized)
struct VectorTileRetirementTests {
    private let key = "osm/14/8800/5700"
    private let vectorHost = "vector.example.invalid"
    // swiftlint:disable force_unwrapping
    private var server: URL { URL(string: "https://\(vectorHost)/")! }
    private let rasterURL = URL(string: "https://raster.example.invalid/14/8800/5700.png")!
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

    /// Archives drawn from `planet-old`, with `extras-old` where `extras`,
    /// whose manifest reads answer `answer`.
    private func archives(
        answer: VectorTileArchiveManifest?,
        extras: Bool = false
    ) throws -> (VectorTileArchives, StubVectorTileManifests) {
        let first = VectorTileArchiveManifest.fixture(
            revision: 1, basemap: "planet-old", extras: extras ? "extras-old" : nil
        )
        let manifests = StubVectorTileManifests(answer)
        let archives = VectorTileArchives(
            sources: ["osm": try #require(first.source(on: server))],
            server: server,
            manifests: manifests
        )
        return (archives, manifests)
    }

    /// The tile server draws land from the archives in `live` and answers
    /// 410 for any other; the raster template answers with a raster tile.
    private func serve(_ live: Set<String>) {
        let host = vectorHost
        let land = StubTileProtocol.Response(data: landTile)
        StubTileProtocol.respond { url in
            guard url.host() == host else { return .tile() }
            let archive = url.pathComponents.dropFirst().first ?? ""
            return live.contains(archive) ? land : .status(410)
        }
    }

    private var paths: [String] { StubTileProtocol.requests.compactMap { $0.url?.path } }
    private var hosts: [String?] { StubTileProtocol.requests.map { $0.url?.host() } }

    private func isDrawn(_ image: TileImage?) -> Bool {
        image?.cgImage?.width == VectorTileRasterizer.pixelSize
    }

    @Test("a basemap the server no longer has is drawn from the one the manifest names now, not the raster template")
    func retiredBasemapMoves() async throws {
        let (archives, manifests) = try archives(answer: .fixture(revision: 2, basemap: "planet-new"))
        let stub = StubbedTileCache(vectorArchives: archives)
        defer { stub.tearDown() }
        serve(["planet-new"])

        #expect(isDrawn(await stub.cache.loadTile(forKey: key, url: rasterURL)))

        #expect(paths == ["/planet-old/14/8800/5700.mvt", "/planet-new/14/8800/5700.mvt"])
        #expect(manifests.reads == 1)
        #expect(stub.isBrowsed(key))
    }

    /// A manifest that cannot be read, or that still names the archive, has
    /// nothing better to offer, and the tile is the raster template's as a
    /// refused one is. The next tile asks the archive again, and does not
    /// read the manifest within the minute.
    @Test("a retired basemap the manifest names nothing newer for falls back to the raster template", arguments: [
        nil, VectorTileArchiveManifest.fixture(revision: 1, basemap: "planet-old"),
    ])
    func retiredBasemapFallsBack(answer: VectorTileArchiveManifest?) async throws {
        let (archives, manifests) = try archives(answer: answer)
        let stub = StubbedTileCache(vectorArchives: archives)
        defer { stub.tearDown() }
        serve([])

        let image = try #require(await stub.cache.loadTile(forKey: key, url: rasterURL))
        _ = await stub.cache.loadTile(forKey: "osm/14/8801/5700", url: rasterURL)

        #expect(!isDrawn(image))
        #expect(hosts == [vectorHost, rasterURL.host(), vectorHost, rasterURL.host()])
        #expect(manifests.reads == 1)
    }

    @Test("extras the server no longer has are drawn from the ones the manifest names now, and the tile is whole")
    func retiredExtrasMove() async throws {
        let (archives, manifests) = try archives(
            answer: .fixture(revision: 2, basemap: "planet-old", extras: "extras-new"),
            extras: true
        )
        let stub = StubbedTileCache(vectorArchives: archives)
        defer { stub.tearDown() }
        serve(["planet-old", "extras-new"])

        #expect(isDrawn(await stub.cache.loadTile(forKey: key, url: rasterURL)))

        #expect(Set(paths.prefix(2)) == ["/planet-old/14/8800/5700.mvt", "/extras-old/14/8800/5700.mvt"])
        #expect(Array(paths.dropFirst(2)) == ["/extras-new/14/8800/5700.mvt"], "the basemap's tile is kept")
        #expect(manifests.reads == 1)
        #expect(stub.isBrowsed(key), "filed, so drawn with its extras")
    }

    @Test("a tile drawn before the archives moved is drawn again from the new ones")
    func tileDrawnBeforeAMoveIsRedrawn() async throws {
        let (archives, _) = try archives(answer: .fixture(revision: 2, basemap: "planet-new"))
        let stub = StubbedTileCache(vectorArchives: archives)
        defer { stub.tearDown() }
        serve(["planet-old", "planet-new"])
        #expect(isDrawn(await stub.cache.loadTile(forKey: key, url: rasterURL)))
        #expect(stub.cache.memoryImage(forKey: key) != nil, "precondition: current")

        await archives.refresh()?.value

        #expect(stub.cache.memoryImage(forKey: key) == nil, "no longer current")
        #expect(isDrawn(await stub.cache.loadTile(forKey: key, url: rasterURL)))
        #expect(paths == ["/planet-old/14/8800/5700.mvt", "/planet-new/14/8800/5700.mvt"])
    }
}
