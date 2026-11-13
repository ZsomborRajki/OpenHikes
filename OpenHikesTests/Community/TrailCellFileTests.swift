//
//  TrailCellFileTests.swift
//  OpenHikesTests
//
//  The bytes of a pre-built square: that what is written is what is read, that
//  a file written yesterday still reads, and that bytes which are not a square
//  are refused rather than drawn.
//
//  The format has two writers of record — this app's encoder, compiled into
//  the tool behind `Scripts/trail-cells.sh` — and every installed build is a
//  reader of whatever is in the public database. So the case that matters
//  most here is the one with bytes spelled out: a file the tool wrote from a
//  three-node extract, which has to go on decoding to the same route however
//  the encoder beside it is tidied.
//

import Foundation
@testable import OpenHikes
import Testing

@Suite("Trail cell file")
struct TrailCellFileTests {
    // MARK: - Fixtures

    /// The square `Scripts/trail-cells.sh` built from an extract of one
    /// relation, two ways and three nodes: OpenStreetMap's 47.6240004 and
    /// 12.9750006 rounded to millionths, a role, and a name carrying every
    /// character OPL escapes.
    private static let toolBuiltSquare = """
    4f4854430100 63 c0843d 07 046e616d65 \
    1d4e656172204c6f6f702c2065617374203d2077657374204020313030 25 \
    05726f757465 0668696b696e67 0474797065 00 07666f7277617264 \
    01 c801 03 0001 0203 0402 02 \
    05 02 c0feb42d a0a0af0c c03e 924e \
    06 02 00 00 c03e 8e4e
    """

    private static let toolBuiltRelation = TrailCellFile.Relation(
        id: 100,
        tags: ["name": "Near Loop, east = west @ 100%", "route": "hiking", "type": "route"],
        ways: [
            TrailCellFile.Way(
                role: "",
                points: [TrailCellFixture.point(47.62, 12.97), TrailCellFixture.point(47.624, 12.975001)]
            ),
            TrailCellFile.Way(
                role: "forward",
                points: [TrailCellFixture.point(47.624, 12.975001), TrailCellFixture.point(47.628, 12.98)]
            ),
        ]
    )

    private static func bytes(hex: String) -> Data {
        let digits = hex.filter(\.isHexDigit)
        var data = Data()
        var index = digits.startIndex
        while index < digits.endIndex {
            let next = digits.index(index, offsetBy: 2)
            data.append(UInt8(digits[index..<next], radix: 16) ?? 0)
            index = next
        }
        return data
    }

    /// A square with enough in it that packing it is worth it: routes on both
    /// sides of the equator and of Greenwich, so every step has both signs.
    private static var busySquare: TrailCellFile {
        let relations = (0..<40).map { index -> TrailCellFile.Relation in
            let sign = index.isMultiple(of: 2) ? 1.0 : -1.0
            let points = (0..<50).map { step in
                TrailCellFixture.point(
                    sign * (0.1 + Double(step) / 10_000),
                    -sign * (0.2 + Double(step * index) / 20_000)
                )
            }
            return TrailCellFile.Relation(
                id: Int64(1000 + index * 7),
                tags: ["name": "Route \(index)", "route": "hiking", "network": "lwn"],
                ways: [
                    TrailCellFile.Way(role: "", points: Array(points.prefix(30))),
                    TrailCellFile.Way(role: "alternative", points: Array(points.suffix(21))),
                ]
            )
        }
        return TrailCellFile(relations: relations)
    }

    private static func expectRefusal(
        of data: Data,
        as expected: TrailCellFileError,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(throws: expected, sourceLocation: sourceLocation) {
            try TrailCellFile(decoding: data)
        }
    }

    // MARK: - What is written is what is read

    @Test("a square reads back as what was written")
    func roundTrip() throws {
        let written = Self.busySquare

        let read = try TrailCellFile(decoding: written.encoded())

        #expect(read == written)
    }

    @Test("a busy square is packed, and a packed square reads back")
    func aBusySquareIsPacked() throws {
        let square = Self.busySquare

        let file = square.encoded()

        #expect(file.count < square.encodedBody().count, "the envelope is a few bytes; the body shrank by more")
        #expect(try TrailCellFile(decoding: file) == square)
    }

    @Test("a square with no routes is a file, and reads back empty")
    func anEmptySquare() throws {
        let read = try TrailCellFile(decoding: TrailCellFile(relations: []).encoded())

        #expect(read.relations.isEmpty)
        #expect(read.coordinateScale == TrailCellFile.standardCoordinateScale)
    }

    /// The digest an upload compares is taken over the body, so the body
    /// cannot depend on the order a dictionary happened to hand its tags
    /// over in — which differs between two runs of the same program.
    @Test("the same routes give the same body, whatever order their tags were added in")
    func theBodyIsDeterministic() {
        var forwards: [String: String] = [:]
        var backwards: [String: String] = [:]
        let tags = (0..<32).map { (key: "key\($0)", value: "value\($0)") }
        for tag in tags { forwards[tag.key] = tag.value }
        for tag in tags.reversed() { backwards[tag.key] = tag.value }
        let way = TrailCellFile.Way(role: "", points: [TrailCellFixture.point(1, 2)])

        let first = TrailCellFile(relations: [TrailCellFile.Relation(id: 1, tags: forwards, ways: [way])])
        let second = TrailCellFile(relations: [TrailCellFile.Relation(id: 1, tags: backwards, ways: [way])])

        #expect(first.encodedBody() == second.encodedBody())
    }

    // MARK: - A file written elsewhere

    @Test("a square the tool wrote reads as the route it was built from")
    func theToolsBytesDecode() throws {
        let read = try TrailCellFile(decoding: Self.bytes(hex: Self.toolBuiltSquare))

        #expect(read.coordinateScale == 1_000_000)
        #expect(read.relations == [Self.toolBuiltRelation])
    }

    /// The other direction, which is what keeps the tool's digests stable:
    /// the encoder beside this decoder writes the bytes the tool wrote.
    @Test("the same route is written as the bytes the tool wrote")
    func theToolsBytesAreWhatIsWritten() {
        let written = TrailCellFile(relations: [Self.toolBuiltRelation]).encoded()

        #expect(written == Self.bytes(hex: Self.toolBuiltSquare))
    }

    // MARK: - Bytes that are not a square

    @Test("bytes that do not start as a square are refused")
    func wrongMagic() {
        var file = Self.bytes(hex: Self.toolBuiltSquare)
        file[0] = UInt8(ascii: "X")

        Self.expectRefusal(of: file, as: .notACell)
    }

    @Test("a version this build does not read is refused, and named")
    func aNewerVersion() {
        var file = Self.bytes(hex: Self.toolBuiltSquare)
        file[4] = 2

        Self.expectRefusal(of: file, as: .unsupportedVersion(2))
    }

    @Test("a packing this build does not know is refused, and named")
    func anUnknownPacking() {
        var file = Self.bytes(hex: Self.toolBuiltSquare)
        file[5] = 9

        Self.expectRefusal(of: file, as: .unsupportedCompression(9))
    }

    @Test("a file cut short is refused", arguments: [3, 5, 6, 60, 105])
    func truncated(length: Int) {
        let file = Self.bytes(hex: Self.toolBuiltSquare).prefix(length)

        #expect(throws: TrailCellFileError.self) {
            try TrailCellFile(decoding: Data(file))
        }
    }

    @Test("a packed file cut short is refused")
    func aPackedFileCutShort() {
        let file = Self.busySquare.encoded()

        #expect(throws: TrailCellFileError.self) {
            try TrailCellFile(decoding: Data(file.prefix(file.count / 2)))
        }
    }

    @Test("bytes after the last route are refused")
    func trailingBytes() {
        // The body's length is in the envelope, so a longer body needs a
        // longer length to get as far as the check under test: 99 becomes 100.
        var file = Self.bytes(hex: Self.toolBuiltSquare)
        file[6] += 1
        file.append(0)

        Self.expectRefusal(of: file, as: .corrupt)
    }

    @Test("a point off the Earth is refused rather than drawn")
    func aPointOffTheEarth() {
        let north = TrailCellFile.Point(latitude: 90_000_001, longitude: 0)
        let square = TrailCellFile(relations: [
            TrailCellFile.Relation(id: 1, tags: [:], ways: [TrailCellFile.Way(role: "", points: [north])]),
        ])

        Self.expectRefusal(of: square.encoded(), as: .corrupt)
    }

    /// A step is any 64-bit number the bytes spell, and the largest varint
    /// there is reads as a step of `Int64.min` — a number with no absolute
    /// value. Measuring the cursor with `abs` stopped the app on it, where
    /// neither `try?` nor the fall back to Overpass could help.
    @Test("a step that carries a coordinate to the smallest number there is is refused, not a crash")
    func aStepToTheSmallestNumber() {
        // An unpacked square of one relation, one way and one point, whose
        // latitude step is the ten bytes of `UInt64.max`.
        let file = Self.bytes(hex: "4f4854430100 16 c0843d 01 00 01 02 00 01 00 01 ffffffffffffffffff01 00")

        Self.expectRefusal(of: file, as: .corrupt)
    }

    @Test("a string index past the strings is refused")
    func aStringIndexPastTheEnd() {
        // The first tag's key index: byte 77 of the tool's square, which
        // holds seven strings.
        var file = Self.bytes(hex: Self.toolBuiltSquare)
        file[77] = 7

        Self.expectRefusal(of: file, as: .corrupt)
    }

    @Test("a count larger than the bytes left is refused before anything is allocated for it")
    func aCountPastTheEnd() {
        // The relation count, byte 73, claiming more relations than there
        // are bytes.
        var file = Self.bytes(hex: Self.toolBuiltSquare)
        file[73] = 0x7F

        Self.expectRefusal(of: file, as: .corrupt)
    }
}
