//
//  StableHasherTests.swift
//  OpenHikesSharedTests
//

import Foundation
@testable import OpenHikesShared
import Testing

@Suite("Stable hasher")
struct StableHasherTests {
    /// The published FNV-1a 64 vectors. A hash that drifted from them would
    /// recolour every community trail and orphan every rendered basemap file,
    /// both of which are addressed by it.
    @Test("matches the reference FNV-1a vectors", arguments: [
        ("", UInt64(0xcbf2_9ce4_8422_2325)),
        ("a", UInt64(0xaf63_dc4c_8601_ec8c)),
        ("foobar", UInt64(0x8594_4171_f739_67e8)),
    ])
    func matchesReferenceVectors(input: String, expected: UInt64) {
        #expect(StableHasher.hash(input) == expected)
    }

    @Test("a double hashes as its little-endian bits")
    func doubleIsItsBits() {
        var byDouble = StableHasher()
        byDouble.combine(47.6961)
        var byBytes = StableHasher()
        withUnsafeBytes(of: (47.6961).bitPattern.littleEndian) { byBytes.combine(bytes: $0) }

        #expect(byDouble.value == byBytes.value)
    }
}
