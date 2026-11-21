//
//  VectorTileArchiveTileTests.swift
//  OpenHikesVectorTilesTests
//
//  The bytes a host hands in from an archive of its own
//  (`VectorTileRasterizer.png(ofArchiveTile:…)`) are the vector tile
//  itself, unpacked. A PMTiles archive usually stores its tiles gzipped,
//  and nothing in the package unpacks them, so these hold what packed bytes
//  come to: no tile for a basemap, and nothing drawn for the extras.
//

import CoreGraphics
import Foundation
import ImageIO
@testable import OpenHikesVectorTiles
@testable import OpenHikesVectorTilesTestSupport
import Testing

@Suite("Vector tile archive tiles")
struct VectorTileArchiveTileTests {
    private let tile = VectorTileAddress(z: 14, x: 8800, y: 5700)
    private let grid = VectorTileFixture.grid
    private static let sea = "#AAD3DF"

    /// Land over the whole tile.
    private var basemap: Data {
        VectorTileFixture.data([
            .init(name: "earth", features: [
                .init(
                    type: .polygon,
                    properties: ["kind": .string("earth")],
                    geometry: VectorTileFixture.rectangle(x: 0...grid, y: 0...grid)
                ),
            ]),
        ])
    }

    /// A lake over the left half, which shows only if the extras are drawn.
    private var extras: Data {
        VectorTileFixture.data([
            .init(name: "water", features: [
                .init(
                    type: .polygon,
                    properties: ["kind": .string("water")],
                    geometry: VectorTileFixture.rectangle(x: 0...(grid / 2), y: 0...grid)
                ),
            ]),
        ])
    }

    @Test("an unpacked basemap is drawn, with the unpacked extras over it")
    func unpackedTilesAreDrawn() throws {
        let image = try #require(picture(basemap: basemap, extras: extras))

        #expect(VectorTileFixture.image(image, has: Self.sea))
    }

    @Test("a gzipped basemap reads as no tile")
    func gzippedBasemapIsNoTile() {
        #expect(png(basemap: Self.gzipped(basemap), extras: nil) == nil)
    }

    @Test("gzipped extras are left out of the picture")
    func gzippedExtrasAreLeftOut() throws {
        let image = try #require(picture(basemap: basemap, extras: Self.gzipped(extras)))

        #expect(!VectorTileFixture.image(image, has: Self.sea))
    }

    private func png(basemap: Data, extras: Data?) -> Data? {
        VectorTileRasterizer.png(
            ofArchiveTile: basemap,
            extras: extras,
            from: tile,
            drawing: tile,
            language: "en",
            height: VectorTileFixture.height
        )
    }

    private func picture(basemap: Data, extras: Data?) -> CGImage? {
        guard let png = png(basemap: basemap, extras: extras),
              let source = CGImageSourceCreateWithData(png as CFData, nil)
        else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// `bytes` as gzip holds them, in a single stored deflate block: a whole
    /// gzip member, as a PMTiles archive of tile compression 2 stores a tile.
    private static func gzipped(_ bytes: Data) -> Data {
        let length = UInt16(bytes.count)
        var packed: [UInt8] = [0x1F, 0x8B, 8, 0, 0, 0, 0, 0, 0, 0xFF]
        packed += [1, UInt8(length & 0xFF), UInt8(length >> 8), UInt8(~length & 0xFF), UInt8(~length >> 8)]
        packed += bytes
        packed += littleEndian(crc32(bytes)) + littleEndian(UInt32(bytes.count))
        return Data(packed)
    }

    private static func crc32(_ bytes: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = crc & 1 == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1
            }
        }
        return ~crc
    }

    private static func littleEndian(_ value: UInt32) -> [UInt8] {
        (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
    }
}
