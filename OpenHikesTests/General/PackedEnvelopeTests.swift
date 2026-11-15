//
//  PackedEnvelopeTests.swift
//  OpenHikesTests
//
//  A packed square's envelope says how long its body is unpacked, and the
//  body is taken only when its DEFLATE stream ends exactly there. A buffer
//  filled to the length the envelope gave proved neither: a file that
//  understated its body was read as the square at the front of it, and a
//  stream cut off after its last byte of output but before its end was read
//  as though it had ended.
//

import Foundation
@testable import OpenHikes
import Testing

@Suite("Packed envelope")
struct PackedEnvelopeTests {
    /// Points enough that the body is worth packing.
    private static let points = 500

    @Test("a packed body as long as the envelope says reads", arguments: PackedSquareFormat.allCases)
    func theLengthItSays(_ format: PackedSquareFormat) throws {
        let body = format.body(points: Self.points)
        let packed = try #require(PackedDeflate.compressed(Data(body)))

        let file = format.file(declaring: body.count, packed: Array(packed))

        #expect(try format.reads(file, asSquareOf: Self.points))
    }

    /// The square comes first, so the bytes the envelope admits to are a
    /// square of their own; the rest is what a reader must not leave unread.
    @Test(
        "a packed body longer than the envelope says is refused, not cut to the length it gave",
        arguments: PackedSquareFormat.allCases
    )
    func aLongerBody(_ format: PackedSquareFormat) throws {
        let square = format.body(points: Self.points)
        let packed = try #require(PackedDeflate.compressed(Data(square + Array(repeating: 0, count: 1000))))

        format.expectCorrupt(format.file(declaring: square.count, packed: Array(packed)))
    }

    @Test("a packed body shorter than the envelope says is refused", arguments: PackedSquareFormat.allCases)
    func aShorterBody(_ format: PackedSquareFormat) throws {
        let body = format.body(points: Self.points)
        let packed = try #require(PackedDeflate.compressed(Data(body)))

        format.expectCorrupt(format.file(declaring: body.count + 1, packed: Array(packed)))
    }

    /// Cut by a byte, this square's stream still gives the whole body — the
    /// last byte holds little more than the stream's end — which is what the
    /// one-shot decoder answered as the whole of it.
    @Test(
        "a packed stream cut short is refused, even where what it gave is the whole body",
        arguments: PackedSquareFormat.allCases
    )
    func aStreamCutShort(_ format: PackedSquareFormat) throws {
        let body = format.body(points: Self.points)
        let packed = Array(try #require(PackedDeflate.compressed(Data(body))))

        for cut in [1, 2, packed.count / 2] {
            let file = format.file(declaring: body.count, packed: Array(packed.dropLast(cut)))
            format.expectCorrupt(file, "the stream cut by \(cut)")
        }
    }

    /// The decoder hands a body that packs as tightly as this one back over
    /// several calls — 128 KB on the first and 64 KB on each after it,
    /// measured on macOS 27 and iOS 18.6 — and a reader that took one call's
    /// worth as the end of the stream would refuse every such square past it.
    @Test("a body unpacked in several pieces reads whole", arguments: PackedSquareFormat.allCases)
    func aLargeBody(_ format: PackedSquareFormat) throws {
        let pointCount = 250_000
        let body = format.body(points: pointCount)
        try #require(body.count > 2 * 128 * 1024, "the body is long enough to take several calls")

        let file = format.file(body: body)

        #expect(file.count < body.count, "the body was packed")
        #expect(try format.reads(file, asSquareOf: pointCount))
    }

    @Test("a body said to be past the largest a reader unpacks is refused", arguments: PackedSquareFormat.allCases)
    func pastTheLargestBody(_ format: PackedSquareFormat) throws {
        let packed = try #require(PackedDeflate.compressed(Data(format.body(points: Self.points))))

        format.expectCorrupt(format.file(declaring: PackedEnvelope.maximumBodyBytes + 1, packed: Array(packed)))
    }
}
