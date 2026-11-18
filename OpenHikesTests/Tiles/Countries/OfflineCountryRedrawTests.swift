//
//  OfflineCountryRedrawTests.swift
//  OpenHikesTests
//
//  A tile the cache drew before a country was installed, or before an update
//  of it, is filed under the same key as the one the country draws now. It
//  is not current, in memory or on either disk, where the country's outline
//  holds it: the load draws it again out of the country, with no request,
//  and leaves alone what lies outside. The responses are
//  `StubTileProtocol`'s, which is process-wide, so the suite is serialized.
//

import CoreGraphics
import Foundation
@testable import OpenHikes
import Testing
import UIKit

@Suite("Offline countries: tiles drawn before an install", .serialized)
struct OfflineCountryRedrawTests {
    /// Zoom 14's tile over Ljubljana, inside the fixture's Slovenia, and one
    /// over Madrid, outside it.
    private static let inside = VectorTileAddress(z: 14, x: 8851, y: 5825)
    private static let outside = VectorTileAddress(z: 14, x: 8023, y: 6178)
    // swiftlint:disable force_unwrapping
    private let rasterURL = URL(string: "https://raster.example.invalid/tile.png")!
    private var sources: [String: VectorTileSource] {
        ["osm": VectorTileSource(archiveURL: URL(string: "https://vector.example.invalid/planet")!, maximumZ: 15)]
    }
    // swiftlint:enable force_unwrapping

    private static func key(_ tile: VectorTileAddress) -> String { "osm/\(tile.z)/\(tile.x)/\(tile.y)" }

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

    /// Slovenia's archive, holding land at the tile over Ljubljana, opened as
    /// `build` installed at `installedAt`.
    private func slovenia(in directory: URL, installedAt: Date, build: String = "20261117") throws
        -> OfflineCountryArchives.Country {
        let bytes = OfflineCountryFixture.archive([Self.inside: landTile], maximumZoom: 14)
        let file = directory.appending(path: "SI-\(build).pmtiles")
        try bytes.write(to: file)
        let country = OfflineCountryFixture.country(bytes: bytes, build: build)
        return OfflineCountryArchives.Country(
            id: "SI",
            bounds: country.bounds,
            basemap: try PMTilesArchive(contentsOf: file),
            extras: nil,
            record: OfflineCountryStore.Record(country: country, installedAt: installedAt)
        )
    }

    private func isDrawn(_ image: TileImage?) -> Bool {
        image?.cgImage?.width == VectorTileRasterizer.pixelSize
    }

    @Test("a browsed tile drawn before the country was installed is drawn again out of it, with no request")
    func browsedTile() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let archives = OfflineCountryArchives()
            let stub = StubbedTileCache(vectorSources: sources, countryArchives: archives)
            defer { stub.tearDown() }
            StubTileProtocol.respond { _ in .tile() }
            try stub.place(in: stub.browsedFile(for: Self.key(Self.inside)), agedByDays: 1)
            try stub.place(in: stub.browsedFile(for: Self.key(Self.outside)), agedByDays: 1)

            archives.replace(with: [try slovenia(in: directory, installedAt: .now)])

            #expect(isDrawn(await stub.cache.loadTile(forKey: Self.key(Self.inside), url: rasterURL)))
            let away = await stub.cache.loadTile(forKey: Self.key(Self.outside), url: rasterURL)
            #expect(away != nil && !isDrawn(away), "the copy outside the country is still current")
            #expect(StubTileProtocol.requests.isEmpty)
        }
    }

    /// The memory tier is what the map's draw pass paints, and the one it
    /// keeps would otherwise answer for a week.
    @Test("a tile in memory drawn before the country was installed is turned away")
    func memoryTile() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let archives = OfflineCountryArchives()
            let stub = StubbedTileCache(vectorSources: sources, countryArchives: archives)
            defer { stub.tearDown() }
            let image = try #require(TileImage(data: TileStore.tileData))
            let insideKey = Self.key(Self.inside)
            let outsideKey = Self.key(Self.outside)
            stub.cache.cacheInMemory(image, storedAt: Self.hoursAgo(1), forKey: insideKey)
            stub.cache.cacheInMemory(image, storedAt: Self.hoursAgo(1), forKey: outsideKey)
            #expect(stub.cache.memoryImage(forKey: insideKey) != nil)

            archives.replace(with: [try slovenia(in: directory, installedAt: Self.hoursAgo(0.5))])

            #expect(stub.cache.memoryImage(forKey: insideKey) == nil)
            #expect(stub.cache.memoryImage(forKey: outsideKey) != nil)
            stub.cache.cacheInMemory(image, storedAt: .now, forKey: insideKey)
            #expect(stub.cache.memoryImage(forKey: insideKey) != nil, "a tile drawn since is current")
        }
    }

    /// Saved coverage is the hiker's map with no signal, so it is drawn while
    /// the country draws its replacement, and the replacement stays saved.
    @Test("a saved tile drawn before the country was installed is drawn ahead of its redraw, and redrawn saved")
    func savedTile() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let archives = OfflineCountryArchives()
            let stub = StubbedTileCache(vectorSources: sources, countryArchives: archives)
            defer { stub.tearDown() }
            StubTileProtocol.respond { _ in .tile() }
            let key = Self.key(Self.inside)
            try stub.place(in: stub.savedFile(for: key), agedByDays: 1)

            archives.replace(with: [try slovenia(in: directory, installedAt: .now)])

            let ahead = await stub.cache.loadStoredTileResult(forKey: key)
            #expect(ahead?.disposition == .stale)
            #expect(ahead.map { !isDrawn($0.image) } == true)
            let redrawn = await stub.cache.refreshStaleTileResult(forKey: key, url: rasterURL)
            #expect(redrawn.disposition == .loaded)
            #expect(isDrawn(redrawn.image))
            #expect(stub.isSaved(key) && !stub.isBrowsed(key))
            #expect(StubTileProtocol.requests.isEmpty)
        }
    }

    /// An update is installed before its archive is opened, and the old
    /// build draws until then, so the tiles drawn in between are drawn again
    /// too. Opening the same build at launch redraws nothing.
    @Test("an update redraws what the build it replaced drew while it was being opened")
    func updateReplacesABuild() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let archives = OfflineCountryArchives()
            let old = try slovenia(in: directory, installedAt: Self.hoursAgo(48), build: "20261001")
            archives.replace(with: [old])
            #expect(!archives.redraws(Self.inside, drawnAt: Self.hoursAgo(0.5)))

            let new = try slovenia(in: directory, installedAt: Self.hoursAgo(1), build: "20261117")
            archives.replace(with: [new])

            #expect(archives.redraws(Self.inside, drawnAt: Self.hoursAgo(0.5)))
            #expect(!archives.redraws(Self.outside, drawnAt: Self.hoursAgo(0.5)))

            let relaunched = OfflineCountryArchives()
            relaunched.replace(with: [new])
            #expect(!relaunched.redraws(Self.inside, drawnAt: Self.hoursAgo(0.5)))
            #expect(relaunched.redraws(Self.inside, drawnAt: Self.hoursAgo(2)))
        }
    }
}
