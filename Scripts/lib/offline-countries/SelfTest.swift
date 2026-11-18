//
//  SelfTest.swift
//  offline-countries
//
//  `selftest`: a made-up world archive, deep enough to need leaf directories,
//  cut along a square and read back through the app's reader. What
//  Scripts/run-script-tests.sh runs, so the tool is held to the app's files
//  it compiles.
//

import Foundation

extension Tool {
    static func selfTest() async throws {
        // The format's own examples for the curve.
        let examples: [((Int, Int, Int), UInt64)] = [
            ((0, 0, 0), 0), ((1, 0, 0), 1), ((1, 0, 1), 2), ((1, 1, 1), 3), ((1, 1, 0), 4),
            ((2, 0, 0), 5), ((12, 3423, 1763), 19_078_479),
        ]
        for ((z, x, y), id) in examples where PMTilesTileID.id(z: z, x: x, y: y) != id {
            fail("tile \(z)/\(x)/\(y) has id \(PMTilesTileID.id(z: z, x: x, y: y)), not \(id)")
        }

        let directory = FileManager.default.temporaryDirectory.appending(path: "offline-countries-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // Every tile of zooms 0 to 7, each holding its own address, except the
        // sea: a quarter of the world, all one tile, written once.
        let maximumZoom = 7
        var tiles: [(id: UInt64, bytes: [UInt8])] = []
        for zoom in 0...maximumZoom {
            for x in 0..<1 << zoom {
                for y in 0..<1 << zoom {
                    let sea = zoom >= 3 && x < 1 << (zoom - 1) && y >= 1 << (zoom - 1)
                    tiles.append((PMTilesTileID.id(z: zoom, x: x, y: y), Array((sea ? "sea" : "\(zoom)/\(x)/\(y)").utf8)))
                }
            }
        }
        tiles.sort { $0.id < $1.id }
        var data: [UInt8] = []
        var entries: [PMTilesEntry] = []
        var sea: UInt64?
        for tile in tiles {
            let isSea = tile.bytes == Array("sea".utf8)
            let offset: UInt64
            if isSea, let written = sea {
                offset = written
            } else {
                offset = UInt64(data.count)
                data += tile.bytes
                if isSea { sea = offset }
            }
            entries.append(PMTilesEntry(tileID: tile.id, offset: offset, length: UInt64(tile.bytes.count), runLength: 1))
        }
        var header = PMTilesHeader()
        header.maximumZoom = UInt8(maximumZoom)
        header.tileType = 1
        let world = directory.appending(path: "world.pmtiles")
        let prefix = PMTilesLayout.prefix(header: header, entries: entries, metadata: Array("{}".utf8),
                                          tileDataLength: UInt64(data.count))
        try Data(prefix + data).write(to: world)
        guard PMTilesLayout.directories(for: entries).leaves.count > 0 else { fail("the world needed no leaves") }

        // A square over the Alps, cut with a margin, and read back.
        let ring: Ring = [(9.5, 46.4), (17.2, 46.4), (17.2, 49.0), (9.5, 49.0), (9.5, 46.4)]
        let coverage = TileCoverage(rings: [ring], marginKilometers: 3, maximumZoom: maximumZoom)
        let wanted = coverage.tiles()
        let extractor = try await Extractor(source: FileSource(url: world))
        let located = try await extractor.locate(wanted.map { PMTilesTileID.id(z: $0.z, x: $0.x, y: $0.y) }.sorted())
        guard located.count == wanted.count else { fail("located \(located.count) of \(wanted.count) tiles") }
        let cut = directory.appending(path: "cut.pmtiles")
        _ = try await extractor.write(located, to: cut, header: header, metadata: Array("{}".utf8))
        let archive = try PMTilesArchive(contentsOf: cut)
        for tile in wanted {
            guard let bytes = try archive.tile(z: tile.z, x: tile.x, y: tile.y),
                  String(decoding: bytes, as: UTF8.self) == "\(tile.z)/\(tile.x)/\(tile.y)"
            else { fail("the cut has the wrong bytes at \(tile)") }
        }
        guard try archive.tile(z: maximumZoom, x: 0, y: 0) == nil else { fail("the cut kept a tile it should not") }
        guard archive.header.isClustered else { fail("the cut is not clustered") }
        print("offline-countries: selftest passed (\(wanted.count) tiles cut, \(tiles.count) in the world)")
    }
}
