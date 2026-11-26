//
//  ElevationSquareFileTests.swift
//  OpenHikesTests
//
//  The square of heights as the tile server holds it: every post reads back
//  as it was written, a post with no height stays one, and bytes that are not
//  a square are refused rather than read as heights.
//

import Foundation
@testable import OpenHikes
import Testing

@Suite("Elevation square file")
struct ElevationSquareFileTests {
    /// A square of `rows` × `columns` posts whose heights are a slope with
    /// a ridge in it, like the ground the format is packed for.
    private static func slope(rows: Int, columns: Int) -> ElevationSquareFile {
        let heights = (0..<rows * columns).map { index -> Int16 in
            let row = index / columns
            let column = index % columns
            return Int16(800 + row * 3 + column * 2 - abs(column - columns / 2))
        }
        return ElevationSquareFile(rows: rows, columns: columns, heights: heights)
    }

    @Test("a square reads back post for post", arguments: [(450, 450), (450, 300), (450, 45)])
    func roundTrip(rows: Int, columns: Int) throws {
        let square = Self.slope(rows: rows, columns: columns)
        #expect(try ElevationSquareFile(decoding: square.encoded()) == square)
    }

    /// The differences wrap at 16 bits, so the extremes, and a post with no
    /// height beside one with a height, are differences like any other.
    @Test("the extremes and posts with no height read back exactly")
    func extremes() throws {
        var heights = Self.slope(rows: 8, columns: 9).heights
        heights[0] = ElevationSquareFile.unknown
        heights[5] = Int16.max
        heights[10] = ElevationSquareFile.unknown
        heights[11] = -430
        heights[30] = 8849
        heights[71] = ElevationSquareFile.unknown
        let square = ElevationSquareFile(rows: 8, columns: 9, heights: heights)

        let read = try ElevationSquareFile(decoding: square.encoded())

        #expect(read == square)
        #expect(read.height(at: 0) == nil)
        #expect(read.height(at: 11) == -430)
        #expect(read.height(at: 30) == 8849)
    }

    /// The whole of the format's argument: a slope is a few metres from the
    /// plane its neighbors make, so the packed square is a fraction of two
    /// bytes a post.
    @Test("a slope packs to a fraction of two bytes a post")
    func packsSmall() {
        let square = Self.slope(rows: 450, columns: 450)
        #expect(square.encoded().count < square.heights.count * 2 / 10)
    }

    @Test("a square of nothing but sea level says so")
    func seaLevel() {
        #expect(ElevationSquareFile(rows: 2, columns: 2, heights: [0, 0, 0, 0]).isSeaLevel)
        #expect(!ElevationSquareFile(rows: 2, columns: 2, heights: [0, 0, 1, 0]).isSeaLevel)
        #expect(!ElevationSquareFile(rows: 1, columns: 1, heights: [ElevationSquareFile.unknown]).isSeaLevel)
    }

    @Test("bytes cut short are no square")
    func truncated() {
        let bytes = Self.slope(rows: 450, columns: 45).encoded()
        #expect(throws: (any Error).self) {
            try ElevationSquareFile(decoding: bytes.prefix(bytes.count - 16))
        }
    }

    @Test("another square file's bytes are no square of heights")
    func anotherFormat() {
        let places = PlaceSquareFile(places: []).encoded()
        #expect(throws: PackedFileError.wrongFormat) {
            try ElevationSquareFile(decoding: places)
        }
        #expect(throws: (any Error).self) {
            try ElevationSquareFile(decoding: Data())
        }
    }

    /// A body that names more posts than it holds, or fewer, would put every
    /// height after the gap on somebody else's post.
    @Test("a body whose size and posts disagree is no square")
    func sizeAndPostsDisagree() {
        let body = ElevationSquareFile(rows: 4, columns: 4, heights: Array(repeating: 100, count: 16)).encodedBody()
        var lying = Data(PackedVarint.bytes(of: 5))
        lying.append(body.dropFirst())
        let file = PackedEnvelope.file(
            magic: Array("OHEL".utf8),
            version: ElevationSquareFile.formatVersion,
            body: lying
        )
        #expect(throws: PackedFileError.corrupt) {
            try ElevationSquareFile(decoding: file)
        }
    }
}
