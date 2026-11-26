//
//  VectorTileDarkMapTests.swift
//  OpenHikesTests
//
//  `TileCache` with the two providers drawn from one vector archive: the
//  OpenHikes map and OpenHikes Dark. One archive tile is each provider's
//  picture in its own colors, filed under its own key. And where the tile
//  server draws nothing, the dark map asks nobody: the raster template's
//  tiles are the light map's, and one of them among the dark ones would be
//  filed for a week. The responses are `StubTileProtocol`'s, which is
//  process-wide, so the suite is serialized.
//

import CoreGraphics
import Foundation
@testable import OpenHikes
import Testing
import UIKit

@Suite("OpenHikes Dark's tiles", .serialized)
struct VectorTileDarkMapTests {
    private static let light = TileProvider.openStreetMap.id
    private static let dark = TileProvider.openHikesDark.id
    private let vectorHost = "vector.example.invalid"
    // swiftlint:disable force_unwrapping
    private let rasterURL = URL(string: "https://raster.example.invalid/14/8800/5700.png")!
    /// Both providers on the one archive, as the app's own are.
    private var sources: [String: VectorTileSource] {
        let planet = VectorTileSource(archiveURL: URL(string: "https://\(vectorHost)/planet")!, maximumZ: 15)
        return [Self.light: planet, Self.dark: planet]
    }
    // swiftlint:enable force_unwrapping

    private static func key(_ providerID: String, x: Int = 8800) -> String { "\(providerID)/14/\(x)/5700" }

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

    private func script(vector: StubTileProtocol.Response) {
        let host = vectorHost
        StubTileProtocol.respond { url in
            url.host() == host ? vector : .tile()
        }
    }

    private var hosts: [String?] { StubTileProtocol.requests.map { $0.url?.host() } }

    private func has(_ image: TileImage?, _ hex: String) -> Bool {
        image?.cgImage.map { VectorTileFixture.image($0, has: hex) } ?? false
    }

    @Test("the catalog's two OpenHikes maps are drawn from the same archive, each in its own colors")
    func catalog() {
        #expect(TileProvider.openHikesDark.vectorSource == TileProvider.openStreetMap.vectorSource)
        #expect(Set(TileProvider.vectorSources.keys) == [Self.light, Self.dark])
        #expect(TileProvider.vectorPalette(forProviderID: Self.light) == .carto)
        #expect(TileProvider.vectorPalette(forProviderID: Self.dark) == .dark)
        #expect(TileProvider.vectorPalette(forProviderID: "stadia_outdoors") == .carto)
        #expect(TileProvider.openStreetMap.fallsBackToRasterTiles)
        #expect(!TileProvider.openHikesDark.fallsBackToRasterTiles)
        #expect(TileProvider.fallsBackToRasterTiles(forKey: Self.key(Self.light)))
        #expect(!TileProvider.fallsBackToRasterTiles(forKey: Self.key(Self.dark)))
        #expect(TileProvider.fallsBackToRasterTiles(forKey: "not a key"))
    }

    @Test("one archive tile is the light map's picture under one key and the dark map's under the other")
    func oneTileTwoPictures() async throws {
        let stub = StubbedTileCache(vectorSources: sources)
        defer { stub.tearDown() }
        script(vector: .init(data: landTile))

        let day = try #require(await stub.cache.loadTile(forKey: Self.key(Self.light), url: rasterURL))
        let night = try #require(await stub.cache.loadTile(forKey: Self.key(Self.dark), url: rasterURL))

        #expect(has(day, "#F2EFE9") && !has(day, "#1C1E20"))
        #expect(has(night, "#1C1E20") && !has(night, "#F2EFE9"))
        #expect(hosts.allSatisfy { $0 == vectorHost }, "neither asked the raster template")
        #expect(stub.isBrowsed(Self.key(Self.light)) && stub.isBrowsed(Self.key(Self.dark)), "each filed as its own")
        #expect(stub.cache.isDrawnFromVectorTiles(Self.key(Self.dark)))
    }

    @Test("a server that fails draws nothing for the dark map, and the raster template is not asked", arguments: [
        503, 404, 403,
    ])
    func noRasterBehindTheDarkMap(status: Int) async {
        let stub = StubbedTileCache(vectorSources: sources)
        defer { stub.tearDown() }
        script(vector: .status(status))

        let night = await stub.cache.loadTile(forKey: Self.key(Self.dark), url: rasterURL)

        #expect(night == nil)
        #expect(hosts == [vectorHost])
        #expect(!stub.isBrowsed(Self.key(Self.dark)), "nothing is filed among the dark tiles")
    }

    /// The same failures hand the light map's tile to the raster template,
    /// as they always did: the template draws that map.
    @Test("the same failing server still hands the light map's tile to the raster template")
    func lightMapStillFallsBack() async throws {
        let stub = StubbedTileCache(vectorSources: sources)
        defer { stub.tearDown() }
        script(vector: .status(503))

        let day = try #require(await stub.cache.loadTile(forKey: Self.key(Self.light), url: rasterURL))

        #expect(day.cgImage?.width != VectorTileRasterizer.pixelSize, "the raster tile")
        #expect(hosts == [vectorHost, rasterURL.host()])
    }

    /// A suite's cache, and a launch for UI tests, has no tile server at
    /// all. The light map then draws its raster template's tiles; the dark
    /// map has none to draw.
    @Test("a cache with no tile server asks nobody for the dark map's tile")
    func noTileServerAtAll() async {
        let stub = StubbedTileCache()
        defer { stub.tearDown() }
        StubTileProtocol.respond { _ in .tile() }

        #expect(await stub.cache.loadTile(forKey: Self.key(Self.dark), url: rasterURL) == nil)
        #expect(StubTileProtocol.requests.isEmpty)
    }

    @Test("a dark tile saved on the device stays the tile while the server fails")
    func savedDarkTileOutlastsAFailingServer() async throws {
        let stub = StubbedTileCache(vectorSources: sources)
        defer { stub.tearDown() }
        script(vector: .status(503))
        try stub.place(in: stub.savedFile(for: Self.key(Self.dark)), agedByDays: 8)

        #expect(await stub.cache.loadTile(forKey: Self.key(Self.dark), url: rasterURL) != nil, "the saved copy")
        #expect(hosts == [vectorHost])
    }
}
