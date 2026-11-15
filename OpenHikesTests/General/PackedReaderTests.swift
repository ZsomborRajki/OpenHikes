//
//  PackedReaderTests.swift
//  OpenHikesTests
//
//  The integers both kinds of pre-built square are spelled in. Ten groups of
//  seven bits hold every 64-bit number with six bits to spare at the top, so
//  the largest number there is reads as itself, and a tenth group that spells
//  anything past it is refused — never shifted out of the number, which
//  read a scale of 2⁶⁴ + 1 as a scale of 1 that every later check passed.
//

import Foundation
@testable import OpenHikes
import Testing

@Suite("Packed reader")
struct PackedReaderTests {
    /// Nine groups that carry on, then the tenth, which is the top bit's.
    private static func tenBytes(_ fill: UInt8, last: UInt8) -> [UInt8] {
        Array(repeating: fill, count: 9) + [last]
    }

    private static func read(_ bytes: [UInt8]) throws -> UInt64 {
        var reader = PackedReader(bytes: bytes)
        return try reader.readVarint()
    }

    @Test(
        "a number reads back as it was written",
        arguments: [0, 1, 127, 128, 16_383, 16_384, 1 << 56, 1 << 63, .max - 1, .max] as [UInt64]
    )
    func roundTrip(_ value: UInt64) throws {
        #expect(try Self.read(PackedVarint.bytes(of: value)) == value)
    }

    @Test("the largest number there is is ten bytes, and reads as itself")
    func theLargestNumber() throws {
        let bytes = Self.tenBytes(0xFF, last: 0x01)

        #expect(PackedVarint.bytes(of: .max) == bytes)
        #expect(try Self.read(bytes) == .max)
    }

    @Test(
        "a tenth group past the one bit a 64-bit number has left is refused, not wrapped",
        arguments: [0x02, 0x03, 0x40, 0x7F] as [UInt8]
    )
    func aTenthGroupPastTheTopBit(_ last: UInt8) {
        #expect(throws: PackedFileError.corrupt, "over nothing but zeros") {
            try Self.read(Self.tenBytes(0x80, last: last))
        }
        #expect(throws: PackedFileError.corrupt, "over every bit below it") {
            try Self.read(Self.tenBytes(0xFF, last: last))
        }
    }

    @Test("a number that goes on past ten bytes is refused")
    func pastTenBytes() {
        #expect(throws: PackedFileError.corrupt) { try Self.read(Self.tenBytes(0xFF, last: 0x81) + [0x00]) }
    }

    /// Still read here: the squares' cursors are what refuse a step to a
    /// number with no absolute value (`TrailCellFileTests`).
    @Test("the largest number is a step to the smallest one")
    func theSmallestStep() throws {
        var reader = PackedReader(bytes: Self.tenBytes(0xFF, last: 0x01))

        #expect(try reader.readStep() == .min)
    }

    @Test("a square whose scale is past 64 bits is refused", arguments: PackedSquareFormat.allCases)
    func aScalePastSixtyFourBits(_ format: PackedSquareFormat) throws {
        // 2⁶⁴ + 1: the low bit, eight empty groups, and a tenth group of 2.
        let scale: [UInt8] = [0x81] + Array(repeating: 0x80, count: 8) + [0x02]

        // The scale the shift used to make of it reads, so it is the bits
        // above the top one that are refused.
        #expect(try format.coordinateScale(of: format.file(body: [0x01] + format.emptyAfterScale)) == 1)
        format.expectCorrupt(format.file(body: scale + format.emptyAfterScale))
    }
}
