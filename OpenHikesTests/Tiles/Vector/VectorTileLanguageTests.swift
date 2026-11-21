//
//  VectorTileLanguageTests.swift
//  OpenHikesTests
//
//  A tile drawn in one language is filed under the same key as the tile
//  drawn in another, from the same archives. After a launch in another
//  language, the copy on disk is not current, from the tile server or a
//  downloaded country alike: the load draws it again, and a saved copy is
//  drawn ahead of its redraw and stays saved. A launch in the same language
//  keeps what it finds. Each launch is one `VectorTileArchives` keeping what
//  it draws by in the test's own file; the responses are
//  `StubTileProtocol`'s, which is process-wide, so the suite is serialized.
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

    private static func hoursAgo(_ hours: Double) -> Date { Date(timeIntervalSinceNow: -hours * 3600) }

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

    private static let drawnInGerman = 3.0 / 24

    /// Slovenia's archive, holding land at ``tile``, installed before either
    /// launch.
    private func slovenia(in directory: URL) throws -> OfflineCountryArchives.Country {
        let bytes = OfflineCountryFixture.archive([Self.tile: landTile], maximumZoom: 14)
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

    /// The tile server draws land; the raster template answers with the
    /// fixture's raster tile.
    private func serveLand() {
        let host = vectorHost
        let land = StubTileProtocol.Response(data: landTile)
        StubTileProtocol.respond { url in url.host() == host ? land : .tile() }
    }

    private var paths: [String] { StubTileProtocol.requests.compactMap { $0.url?.path } }

    private func isDrawn(_ image: TileImage?) -> Bool {
        image?.cgImage?.width == VectorTileRasterizer.pixelSize
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
            serveLand()
            try stub.place(in: stub.browsedFile(for: Self.key), agedByDays: Self.drawnInGerman)

            #expect((stub.cache.freshDiskImage(forKey: Self.key) == nil) == inAnotherLanguage)
            let image = await stub.cache.loadTile(forKey: Self.key, url: rasterURL)

            #expect(image != nil)
            #expect(isDrawn(image) == inAnotherLanguage, "the copy on disk is the fixture's raster tile")
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
            serveLand()
            try stub.place(in: stub.savedFile(for: Self.key), agedByDays: Self.drawnInGerman)

            #expect(stub.cache.freshDiskImage(forKey: Self.key) == nil)
            let ahead = await stub.cache.loadStoredTileResult(forKey: Self.key)
            #expect(ahead?.disposition == .stale)
            #expect(ahead.map { !isDrawn($0.image) } == true)
            let redrawn = await stub.cache.refreshStaleTileResult(forKey: Self.key, url: rasterURL)

            #expect(redrawn.disposition == .loaded)
            #expect(isDrawn(redrawn.image))
            #expect(stub.isSaved(Self.key) && !stub.isBrowsed(Self.key))
            #expect(stub.cache.freshDiskImage(forKey: Self.key) != nil, "current now")
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
            try stub.place(in: stub.browsedFile(for: Self.key), agedByDays: Self.drawnInGerman)

            let image = await stub.cache.loadTile(forKey: Self.key, url: rasterURL)

            #expect(image != nil)
            #expect(isDrawn(image) == inAnotherLanguage, "the copy on disk is the fixture's raster tile")
            #expect(StubTileProtocol.requests.isEmpty)
        }
    }
}
