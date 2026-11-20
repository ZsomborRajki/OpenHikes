//
//  PMTilesArchiveTests.swift
//  OpenHikesTests
//
//  A downloaded country read where it lies: a tile out of the root
//  directory, one behind a leaf, none where the archive has none, and a
//  damaged file refused when it is opened rather than drawn wrong.
//

import Foundation
@testable import OpenHikes
import Testing

@Suite("PMTiles archive")
struct PMTilesArchiveTests {
    @Test("a tile comes back as it was written, and a missing one as nothing")
    func readsTiles() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let url = directory.appending(path: "small.pmtiles")
            let tiles = [
                VectorTileAddress(z: 0, x: 0, y: 0): Data("world".utf8),
                VectorTileAddress(z: 3, x: 4, y: 2): Data("4/2".utf8),
            ]
            try OfflineCountryFixture.archive(tiles, maximumZoom: 3).write(to: url)
            let archive = try PMTilesArchive(contentsOf: url)

            #expect(try archive.tile(z: 0, x: 0, y: 0) == Data("world".utf8))
            #expect(try archive.tile(z: 3, x: 4, y: 2) == Data("4/2".utf8))
            #expect(try archive.tile(z: 3, x: 4, y: 3) == nil)
            // Beyond the archive's zooms, and off the edge of the world.
            #expect(try archive.tile(z: 4, x: 8, y: 4) == nil)
            #expect(try archive.tile(z: 3, x: 8, y: 0) == nil)

            // What auto-save asks of a downloaded country, from the
            // directories alone, agrees.
            #expect(try archive.contains(z: 3, x: 4, y: 2))
            #expect(try !archive.contains(z: 3, x: 4, y: 3))
            #expect(try !archive.contains(z: 4, x: 8, y: 4))
        }
    }

    /// Every tile of zooms 0 to 7 is more entries than a 16 KiB root holds,
    /// which is what a country's archive always is.
    @Test("a tile behind a leaf directory is found")
    func readsThroughLeaves() async throws {
        var tiles: [VectorTileAddress: Data] = [:]
        for zoom in 0...7 {
            for x in 0..<1 << zoom {
                for y in 0..<1 << zoom {
                    tiles[VectorTileAddress(z: zoom, x: x, y: y)] = Data("\(zoom)/\(x)/\(y)".utf8)
                }
            }
        }
        let bytes = OfflineCountryFixture.archive(tiles, maximumZoom: 7)
        let entries = tiles.keys
            .map { PMTilesTileID.id(z: $0.z, x: $0.x, y: $0.y) }
            .sorted()
            .map { PMTilesEntry(tileID: $0, offset: 0, length: 1, runLength: 1) }
        #expect(!PMTilesLayout.directories(for: entries).leaves.isEmpty)

        try await OfflineCountryFixture.withDirectory { directory in
            let url = directory.appending(path: "world.pmtiles")
            try bytes.write(to: url)
            let archive = try PMTilesArchive(contentsOf: url)

            for address in [VectorTileAddress(z: 7, x: 70, y: 45), VectorTileAddress(z: 7, x: 127, y: 127)] {
                let tile = try #require(try archive.tile(z: address.z, x: address.x, y: address.y))
                #expect(String(bytes: tile, encoding: .utf8) == "\(address.z)/\(address.x)/\(address.y)")
                #expect(try archive.contains(z: address.z, x: address.x, y: address.y))
            }
        }
    }

    /// A download cut short, or a file overwritten under its name: the
    /// directories point past the end, which no read may follow.
    @Test("an archive cut short is refused when it is opened")
    func truncated() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let url = directory.appending(path: "short.pmtiles")
            let whole = OfflineCountryFixture.archive(
                [VectorTileAddress(z: 0, x: 0, y: 0): Data(repeating: 7, count: 1000)],
                maximumZoom: 0
            )
            try whole.prefix(whole.count - 10).write(to: url)

            #expect(throws: PMTilesError.truncated) { try PMTilesArchive(contentsOf: url) }
        }
    }
}
