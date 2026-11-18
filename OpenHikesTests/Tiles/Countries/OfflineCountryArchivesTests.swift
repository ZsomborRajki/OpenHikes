//
//  OfflineCountryArchivesTests.swift
//  OpenHikesTests
//
//  Which bytes the map draws a tile from when a country is downloaded: the
//  tile itself where the country holds its zoom, the deepest one above it
//  where the map is zoomed past the country's, and nothing at all outside
//  the country, so the tile goes on to the server as it always did.
//

import Foundation
@testable import OpenHikes
import Testing

@Suite("Offline country archives")
struct OfflineCountryArchivesTests {
    /// Zoom 2's tile over Ljubljana, and the one zoom 3 tile under it there.
    private static let parent = VectorTileAddress(z: 2, x: 2, y: 1)
    private static let child = VectorTileAddress(z: 3, x: 4, y: 2)

    private func archives(in directory: URL) throws -> OfflineCountryArchives {
        let basemap = directory.appending(path: "SI-20261117.pmtiles")
        let extras = directory.appending(path: "SI-extras-20261117.pmtiles")
        let basemapBytes = OfflineCountryFixture.archive(
            [Self.parent: Data("parent".utf8), Self.child: Data("child".utf8)],
            maximumZoom: 3
        )
        try basemapBytes.write(to: basemap)
        try OfflineCountryFixture.archive([Self.child: Data("extras".utf8)], maximumZoom: 3).write(to: extras)
        let archives = OfflineCountryArchives()
        archives.replace(with: [
            OfflineCountryArchives.Country(
                id: "SI",
                bounds: OfflineCountryFixture.bounds,
                basemap: try PMTilesArchive(contentsOf: basemap),
                extras: try PMTilesArchive(contentsOf: extras)
            ),
        ])
        return archives
    }

    @Test("a tile the country holds is drawn from its own bytes and its extras")
    func ownTile() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let found = try #require(try archives(in: directory).tile(for: Self.child, deepest: 15, extrasFrom: 3))
            #expect(found.dataTile == Self.child)
            #expect(found.basemap == Data("child".utf8))
            #expect(found.extras == Data("extras".utf8))
        }
    }

    /// The server draws past zoom 15 from the zoom-15 tile around it, and a
    /// country cut to fewer zooms does the same from its deepest.
    @Test("past the country's deepest zoom, the tile around it is drawn")
    func overzooms() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let deeper = VectorTileAddress(z: 5, x: 17, y: 11)
            let found = try #require(try archives(in: directory).tile(for: deeper, deepest: 15, extrasFrom: 3))
            #expect(found.dataTile == Self.child)
            #expect(found.basemap == Data("child".utf8))
        }
    }

    @Test("the style's own deepest zoom wins over a deeper country")
    func styleDeepest() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let found = try #require(try archives(in: directory).tile(for: Self.child, deepest: 2, extrasFrom: 3))
            #expect(found.dataTile == Self.parent)
            #expect(found.extras == nil)
        }
    }

    @Test("a tile outside every country is left to the server")
    func outside() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let slovenia = try archives(in: directory)
            let atlantic = VectorTileAddress(z: 3, x: 3, y: 2)
            #expect(slovenia.tile(for: atlantic, deepest: 15, extrasFrom: 3) == nil)
            #expect(OfflineCountryArchives().tile(for: Self.child, deepest: 15, extrasFrom: 3) == nil)
        }
    }

    @Test("a tile's ground is tested against the bounds in degrees")
    func tileBox() {
        let bounds = OfflineCountryFixture.bounds
        #expect(OfflineCountryArchives.box(of: VectorTileAddress(z: 0, x: 0, y: 0), meets: bounds))
        #expect(OfflineCountryArchives.box(of: Self.child, meets: bounds))
        // Zoom 10 tiles just west of the bounds, and over them.
        #expect(!OfflineCountryArchives.box(of: VectorTileAddress(z: 10, x: 548, y: 365), meets: bounds))
        #expect(OfflineCountryArchives.box(of: VectorTileAddress(z: 10, x: 550, y: 365), meets: bounds))
    }
}
