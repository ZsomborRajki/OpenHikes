//
//  VectorTileLanguageTests.swift
//  OpenHikesTests
//
//  A tile drawn in one language is filed under the same key as the tile
//  drawn in another, from the same archives. After a launch in another
//  language, the copy on disk is not current, from the tile server or a
//  downloaded country alike: the load draws it again, in the launch's
//  language, and a saved copy is drawn ahead of its redraw and stays saved,
//  while the server fails too. A launch in the same language keeps what it
//  finds. The tile names one city, in German and in French differently, and
//  every picture is held to the drawing in the language it should be in,
//  pixel for pixel. Each launch is one `VectorTileArchives` keeping what it
//  draws by in the test's own file; the responses are `StubTileProtocol`'s,
//  which is process-wide, so the suite is serialized.
//

import CoreGraphics
import Foundation
@testable import OpenHikes
import Testing
import UIKit

@Suite("Vector tiles: a launch in another language", .serialized)
struct VectorTileLanguageTests {
    /// Zoom 14's tile over Ljubljana, inside the fixture's Slovenia.
    private static let tile = VectorTileAddress(z: 14, x: 8851, y: 5825)
    private static let key = "osm/14/8851/5825"
    private let vectorHost = "vector.example.invalid"
    // swiftlint:disable force_unwrapping
    private var server: URL { URL(string: "https://\(vectorHost)/")! }
    private let rasterURL = URL(string: "https://raster.example.invalid/14/8851/5825.png")!
    // swiftlint:enable force_unwrapping
    /// The same archives at every launch.
    private let manifest = VectorTileArchiveManifest.fixture(revision: 1, basemap: "planet-a")

    /// Land, and a city in the middle named in German and in French, each
    /// unlike the local name.
    private var layers: [VectorTileFixture.Layer] {
        let middle = VectorTileFixture.grid / 2
        return [
            .init(name: "earth", features: [
                .init(
                    type: .polygon,
                    properties: ["kind": .string("earth")],
                    geometry: VectorTileFixture.rectangle(x: 0...VectorTileFixture.grid, y: 0...VectorTileFixture.grid)
                ),
            ]),
            .init(name: "places", features: [
                .init(
                    type: .point,
                    properties: [
                        "kind": .string("locality"),
                        "kind_detail": .string("city"),
                        "name": .string("Ljubljana"),
                        "name:de": .string("Laibach"),
                        "name:fr": .string("Lioubliana"),
                    ],
                    geometry: VectorTileFixture.points([(middle, middle)])
                ),
            ]),
        ]
    }

    private static func hoursAgo(_ hours: Double) -> Date { Date(timeIntervalSinceNow: -hours * 3600) }

    /// The tile as the tile server's client and a country's drawing draw it
    /// in `language`.
    private func drawn(in language: String) throws -> Data {
        try #require(VectorTileRasterizer.png(
            of: try VectorTileFixture.decoded(layers, language: language),
            from: Self.tile,
            drawing: Self.tile,
            language: language,
            height: VectorTileFixture.height
        ))
    }

    /// `image`'s pixels, as sRGB bytes, or none where there is no image.
    private func pixels(of image: CGImage?) -> [UInt8] {
        guard let image, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return [] }
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let drew = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: image.width * 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        return drew ? bytes : []
    }

    /// Whether `image` is the tile drawn in `language`, pixel for pixel.
    private func isDrawn(_ image: TileImage?, in language: String) throws -> Bool {
        let expected = pixels(of: TileImage(data: try drawn(in: language))?.cgImage)
        try #require(!expected.isEmpty)
        return pixels(of: image?.cgImage) == expected
    }

    /// The tile drawn in German three hours ago, as the launch before left
    /// it in `file`.
    private func placeDrawnInGerman(in file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try drawn(in: "de").write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: Self.hoursAgo(3)], ofItemAtPath: file.path)
    }

    /// What a launch in `language` at `date` draws from, keeping it in
    /// `directory` for the next.
    private func launch(in language: String, at date: Date, keepingIn directory: URL) throws -> VectorTileArchives {
        try #require(VectorTileArchives(
            providerIDs: ["osm"],
            bundled: manifest,
            manifests: nil,
            file: directory.appending(path: "kept.json"),
            language: language,
            server: server,
            launchedAt: date
        ))
    }

    /// The archives of a launch now, after one in German four hours ago that
    /// drew a tile three hours ago: now in German too, or in French.
    private func launchAfterGerman(inAnotherLanguage: Bool, keepingIn directory: URL) throws -> VectorTileArchives {
        _ = try launch(in: "de", at: Self.hoursAgo(4), keepingIn: directory)
        return try launch(in: inAnotherLanguage ? "fr" : "de", at: Self.hoursAgo(1), keepingIn: directory)
    }

    /// Slovenia's archive, holding the tile, installed before either launch.
    private func slovenia(in directory: URL) throws -> OfflineCountryArchives.Country {
        let bytes = OfflineCountryFixture.archive([Self.tile: VectorTileFixture.data(layers)], maximumZoom: 14)
        let file = directory.appending(path: "SI-20261117.pmtiles")
        try bytes.write(to: file)
        let country = OfflineCountryFixture.country(bytes: bytes)
        return OfflineCountryArchives.Country(
            id: "SI",
            bounds: country.bounds,
            basemap: try PMTilesArchive(contentsOf: file),
            extras: nil,
            record: OfflineCountryStore.Record(country: country, installedAt: Self.hoursAgo(6))
        )
    }

    /// The tile server answers `vector` (the tile, by default); the raster
    /// template answers with the fixture's raster tile.
    private func serve(vector: StubTileProtocol.Response? = nil) {
        let host = vectorHost
        let answer = vector ?? StubTileProtocol.Response(data: VectorTileFixture.data(layers))
        StubTileProtocol.respond { url in url.host() == host ? answer : .tile() }
    }

    private var paths: [String] { StubTileProtocol.requests.compactMap { $0.url?.path } }

    /// Otherwise a renderer that drew every tile in German would pass.
    @Test("the city is drawn differently in German and in French")
    func languagesDiffer() throws {
        #expect(try !isDrawn(TileImage(data: try drawn(in: "de")), in: "fr"))
        #expect(try isDrawn(TileImage(data: try drawn(in: "fr")), in: "fr"))
    }

    @Test(
        "a browsed tile drawn in another language is drawn again off the server, and one in the same is current",
        arguments: [false, true]
    )
    func serverTile(inAnotherLanguage: Bool) async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let archives = try launchAfterGerman(inAnotherLanguage: inAnotherLanguage, keepingIn: directory)
            let stub = StubbedTileCache(vectorArchives: archives)
            defer { stub.tearDown() }
            serve()
            try placeDrawnInGerman(in: stub.browsedFile(for: Self.key))

            #expect((stub.cache.freshDiskImage(forKey: Self.key) == nil) == inAnotherLanguage)
            let image = await stub.cache.loadTile(forKey: Self.key, url: rasterURL)

            #expect(try isDrawn(image, in: inAnotherLanguage ? "fr" : "de"))
            #expect(paths == (inAnotherLanguage ? ["/planet-a/14/8851/5825.mvt"] : []))
        }
    }

    /// Saved coverage is the hiker's map with no signal, so it is drawn while
    /// the server draws its replacement, and the replacement stays saved.
    @Test("a saved tile drawn in another language is drawn ahead of its redraw, and redrawn saved")
    func savedTile() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let archives = try launchAfterGerman(inAnotherLanguage: true, keepingIn: directory)
            let stub = StubbedTileCache(vectorArchives: archives)
            defer { stub.tearDown() }
            serve()
            try placeDrawnInGerman(in: stub.savedFile(for: Self.key))

            #expect(stub.cache.freshDiskImage(forKey: Self.key) == nil)
            let ahead = await stub.cache.loadStoredTileResult(forKey: Self.key)
            #expect(ahead?.disposition == .stale)
            #expect(try isDrawn(ahead?.image, in: "de"))
            let redrawn = await stub.cache.refreshStaleTileResult(forKey: Self.key, url: rasterURL)

            #expect(redrawn.disposition == .loaded)
            #expect(try isDrawn(redrawn.image, in: "fr"))
            #expect(stub.isSaved(Self.key) && !stub.isBrowsed(Self.key))
            #expect(stub.cache.freshDiskImage(forKey: Self.key) != nil, "current now")
        }
    }

    /// The raster template's tile would replace the saved copy for a week,
    /// with the local names, and the drawing in French would wait that long.
    @Test("a saved tile drawn in another language stays saved, and due, while the server fails")
    func savedTileWhileTheServerFails() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let archives = try launchAfterGerman(inAnotherLanguage: true, keepingIn: directory)
            let stub = StubbedTileCache(vectorArchives: archives)
            defer { stub.tearDown() }
            serve(vector: .status(503))
            let file = stub.savedFile(for: Self.key)
            try placeDrawnInGerman(in: file)

            let refreshed = await stub.cache.refreshStaleTileResult(forKey: Self.key, url: rasterURL)
            let loaded = await stub.cache.loadTile(forKey: Self.key, url: rasterURL)

            #expect(refreshed.disposition == .failed, "the map has the saved copy drawn already")
            #expect(try isDrawn(loaded, in: "de"), "the saved copy, not the raster template's tile")
            #expect(try Data(contentsOf: file) == (try drawn(in: "de")))
            #expect(stub.cache.freshDiskImage(forKey: Self.key) == nil, "still to be drawn again")
            #expect(StubTileProtocol.requests.map { $0.url?.host() } == [vectorHost], "no raster request")
        }
    }

    @Test(
        "a tile a downloaded country drew in another language is drawn again out of it, with no request",
        arguments: [false, true]
    )
    func countryTile(inAnotherLanguage: Bool) async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let archives = try launchAfterGerman(inAnotherLanguage: inAnotherLanguage, keepingIn: directory)
            let countries = OfflineCountryArchives()
            countries.replace(with: [try slovenia(in: directory)])
            let stub = StubbedTileCache(vectorArchives: archives, countryArchives: countries)
            defer { stub.tearDown() }
            StubTileProtocol.respond { _ in .tile() }
            try placeDrawnInGerman(in: stub.browsedFile(for: Self.key))

            let image = await stub.cache.loadTile(forKey: Self.key, url: rasterURL)

            #expect(try isDrawn(image, in: inAnotherLanguage ? "fr" : "de"))
            #expect(StubTileProtocol.requests.isEmpty)
        }
    }
}
