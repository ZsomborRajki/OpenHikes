//
//  PMTilesFileTests.swift
//  OpenHikesTests
//
//  The PMTiles format a downloaded country is kept in: how the format
//  numbers tiles, the header and the directories written and read back, and
//  gzip as the planet packs its tiles. The cutting tool compiles the same
//  file, so what holds here holds for the files it writes.
//

import Foundation
@testable import OpenHikes
import Testing

@Suite("PMTiles format")
struct PMTilesFileTests {
    /// The format's own examples, and one from deep in the planet.
    @Test(
        "tiles are numbered along the format's Hilbert curve",
        arguments: [
            (0, 0, 0, UInt64(0)), (1, 0, 0, 1), (1, 0, 1, 2), (1, 1, 1, 3), (1, 1, 0, 4), (2, 0, 0, 5),
            (12, 3423, 1763, 19_078_479),
        ]
    )
    func tileIDs(z: Int, x: Int, y: Int, id: UInt64) {
        #expect(PMTilesTileID.id(z: z, x: x, y: y) == id)
    }

    @Test("a header reads back as it was written")
    func headerRoundTrip() throws {
        var header = PMTilesHeader()
        header.rootDirectoryOffset = 127
        header.rootDirectoryLength = 1000
        header.tileDataOffset = 50_000
        header.tileDataLength = 460_046_057
        header.isClustered = true
        header.tileCompression = PMTilesCompression.gzip.rawValue
        header.tileType = 1
        header.maximumZoom = 15
        header.bounds = [133_264_160, 453_907_352, 165_673_828, 468_977_391]
        header.center = [149_000_000, 460_500_000]

        #expect(header.bytes.count == PMTilesHeader.byteCount)
        #expect(try PMTilesHeader(bytes: header.bytes) == header)
    }

    @Test("bytes that are not an archive are refused")
    func notAnArchive() {
        #expect(throws: PMTilesError.notPMTiles) {
            try PMTilesHeader(bytes: [UInt8](repeating: 0, count: PMTilesHeader.byteCount))
        }
        #expect(throws: PMTilesError.truncated) {
            try PMTilesHeader(bytes: Array(PMTilesHeader().bytes.prefix(20)))
        }
    }

    /// A version 2 archive lays its directories out differently, and read as
    /// a version 3 one it would hand back other tiles' bytes.
    @Test("an archive of another version is refused")
    func otherVersion() {
        var bytes = PMTilesHeader().bytes
        bytes[PMTilesHeader.magic.count] = 2
        #expect(throws: PMTilesError.unsupportedVersion(2)) { try PMTilesHeader(bytes: bytes) }
    }

    /// Two entries sharing their bytes is how the planet stores the sea once.
    @Test("a directory reads back as written, runs and shared bytes included")
    func directoryRoundTrip() throws {
        let entries = [
            PMTilesEntry(tileID: 0, offset: 0, length: 10, runLength: 1),
            PMTilesEntry(tileID: 1, offset: 10, length: 5, runLength: 3),
            PMTilesEntry(tileID: 5, offset: 10, length: 5, runLength: 1),
            PMTilesEntry(tileID: 900, offset: 15, length: 20, runLength: 1),
        ]
        #expect(try PMTilesDirectory.entries(from: PMTilesDirectory.bytes(of: entries)) == entries)
    }

    @Test("a run holds the tiles after its first, and a gap holds none")
    func entryLookup() {
        let run = PMTilesEntry(tileID: 10, offset: 0, length: 4, runLength: 3)
        let single = PMTilesEntry(tileID: 20, offset: 4, length: 4, runLength: 1)
        let entries = [run, single]

        #expect(PMTilesDirectory.entry(holding: 10, in: entries) == run)
        #expect(PMTilesDirectory.entry(holding: 12, in: entries) == run)
        #expect(PMTilesDirectory.entry(holding: 13, in: entries) == nil)
        #expect(PMTilesDirectory.entry(holding: 9, in: entries) == nil)
        #expect(PMTilesDirectory.entry(holding: 20, in: entries) == single)
        #expect(PMTilesDirectory.entry(holding: 21, in: entries) == nil)
    }

    /// A leaf holds every tile up to the next entry, whatever its run says.
    @Test("a leaf directory is the one for every tile up to the next entry")
    func leafLookup() {
        let leaf = PMTilesEntry(tileID: 100, offset: 0, length: 40, runLength: 0)
        let next = PMTilesEntry(tileID: 500, offset: 40, length: 40, runLength: 0)

        #expect(PMTilesDirectory.entry(holding: 499, in: [leaf, next]) == leaf)
        #expect(PMTilesDirectory.entry(holding: 99, in: [leaf, next]) == nil)
    }

    @Test("gzip unpacks as the planet packs its tiles")
    func gzip() throws {
        // `gzip.compress(b"hello", mtime=0)`.
        let hello: [UInt8] = [
            0x1F, 0x8B, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF, 0xCB, 0x48, 0xCD,
            0xC9, 0xC9, 0x07, 0x00, 0x86, 0xA6, 0x10, 0x36, 0x05, 0x00, 0x00, 0x00,
        ]
        let unpacked = try PMTilesGzip.unpacked(hello, compression: PMTilesCompression.gzip.rawValue)
        #expect(unpacked == Array("hello".utf8))
        #expect(throws: PMTilesError.corrupt) {
            try PMTilesGzip.unpacked(Array(hello.prefix(12)), compression: PMTilesCompression.gzip.rawValue)
        }
    }

    /// Planetiler writes a tile whose features all clip away as gzip of
    /// nothing, and the extras hold such tiles: Bulgaria's zoom 15 has one.
    @Test("gzip of an empty tile unpacks to nothing, and a stream with more in it is refused")
    func emptyGzip() throws {
        // `gzip.compress(b"", mtime=0)`.
        let empty: [UInt8] = [
            0x1F, 0x8B, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF, 0x03, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        ]
        #expect(try PMTilesGzip.unpacked(empty, compression: PMTilesCompression.gzip.rawValue).isEmpty)
        // `hello`'s stream behind an empty tile's trailer.
        let saidEmpty = Array(empty.prefix(10)) + [0xCB, 0x48, 0xCD, 0xC9, 0xC9, 0x07, 0x00] + Array(empty.suffix(8))
        #expect(throws: PMTilesError.corrupt) {
            try PMTilesGzip.unpacked(saidEmpty, compression: PMTilesCompression.gzip.rawValue)
        }
    }

    @Test("brotli and zstd are refused rather than misread")
    func otherCompressions() {
        for compression in [PMTilesCompression.brotli, .zstd] {
            #expect(throws: PMTilesError.unsupportedCompression(compression.rawValue)) {
                try PMTilesGzip.unpacked([1, 2, 3], compression: compression.rawValue)
            }
        }
    }
}
