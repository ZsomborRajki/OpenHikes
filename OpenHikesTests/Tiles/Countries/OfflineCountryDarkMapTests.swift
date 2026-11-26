//
//  OfflineCountryDarkMapTests.swift
//  OpenHikesTests
//
//  A downloaded country is the vector tiles themselves, so it is every map's
//  that is drawn from them: the OpenHikes map's and OpenHikes Dark's alike,
//  each in its own colors, with no request and no second download. The
//  responses are `StubTileProtocol`'s, which is process-wide, so the suite is
//  serialized.
//

import CoreGraphics
import Foundation
@testable import OpenHikes
import Testing
import UIKit

@Suite("Offline countries: OpenHikes Dark", .serialized)
struct OfflineCountryDarkMapTests {
    /// Zoom 14's tile over Ljubljana, inside the fixture's Slovenia.
    private static let inside = VectorTileAddress(z: 14, x: 8851, y: 5825)
    // swiftlint:disable force_unwrapping
    private let rasterURL = URL(string: "https://raster.example.invalid/tile.png")!
    private var sources: [String: VectorTileSource] {
        let planet = VectorTileSource(archiveURL: URL(string: "https://vector.example.invalid/planet")!, maximumZ: 15)
        return [TileProvider.openStreetMap.id: planet, TileProvider.openHikesDark.id: planet]
    }
    // swiftlint:enable force_unwrapping

    private static func key(_ provider: TileProvider) -> String {
        "\(provider.id)/\(inside.z)/\(inside.x)/\(inside.y)"
    }

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

    private func slovenia(in directory: URL) throws -> OfflineCountryArchives.Country {
        let bytes = OfflineCountryFixture.archive([Self.inside: landTile], maximumZoom: 14)
        let file = directory.appending(path: "SI-20261117.pmtiles")
        try bytes.write(to: file)
        let country = OfflineCountryFixture.country(bytes: bytes, build: "20261117")
        return OfflineCountryArchives.Country(
            id: "SI",
            bounds: country.bounds,
            basemap: try PMTilesArchive(contentsOf: file),
            extras: nil,
            record: OfflineCountryStore.Record(country: country, installedAt: .now)
        )
    }

    private func has(_ image: TileImage?, _ hex: String) -> Bool {
        image?.cgImage.map { VectorTileFixture.image($0, has: hex) } ?? false
    }

    @Test("one downloaded country draws the light map's tile and the dark map's, with no request")
    func oneCountryTwoPictures() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let archives = OfflineCountryArchives()
            let stub = StubbedTileCache(vectorSources: sources, countryArchives: archives)
            defer { stub.tearDown() }
            StubTileProtocol.respond { _ in .status(503) }
            archives.replace(with: [try slovenia(in: directory)])

            let day = await stub.cache.loadTile(forKey: Self.key(.openStreetMap), url: rasterURL)
            let night = await stub.cache.loadTile(forKey: Self.key(.openHikesDark), url: rasterURL)

            #expect(has(day, "#F2EFE9") && !has(day, "#1C1E20"))
            #expect(has(night, "#1C1E20") && !has(night, "#F2EFE9"))
            #expect(StubTileProtocol.requests.isEmpty)
            #expect(stub.cache.isHeldByDownloadedCountry(Self.key(.openHikesDark)))
            #expect(stub.cache.isHeldByDownloadedCountry(Self.key(.openStreetMap)))
        }
    }
}
