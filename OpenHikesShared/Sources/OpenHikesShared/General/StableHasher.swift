//
//  StableHasher.swift
//  OpenHikesShared
//
//  A hash that means the same thing in every process on every device.
//
//  `Hasher` cannot be that: Swift seeds it per process, so the same value
//  hashes differently in this launch and the next, and differently again on
//  the other side of the watch link. Everything that needs a hash to survive
//  either — a route colour addressed by a listing id, a basemap file named
//  after its coverage, a trail revision compared across two devices — wants
//  the same thing instead, and FNV-1a is stable by construction.
//
//  Not a cryptographic hash, and nothing here needs one: every caller asks
//  "is this the same input as before", never "could somebody forge this".
//

import Foundation

/// FNV-1a, 64-bit. Wrapping arithmetic throughout, which is the algorithm
/// rather than an accommodation of it.
public struct StableHasher: Sendable {
    private static let offsetBasis: UInt64 = 0xcbf2_9ce4_8422_2325
    private static let prime: UInt64 = 0x0000_0100_0000_01b3

    public private(set) var value: UInt64 = Self.offsetBasis

    public init() {
        // Starts from the offset basis, which is what `value` begins as.
    }

    public mutating func combine(bytes: some Sequence<UInt8>) {
        for byte in bytes {
            value = (value ^ UInt64(byte)) &* Self.prime
        }
    }

    public mutating func combine(_ string: String) {
        combine(bytes: string.utf8)
    }

    /// The value's bit pattern, little-endian, so the same `Double` is the
    /// same eight bytes on every device this runs on.
    public mutating func combine(_ double: Double) {
        withUnsafeBytes(of: double.bitPattern.littleEndian) { combine(bytes: $0) }
    }

    public mutating func combine(_ uuid: UUID) {
        withUnsafeBytes(of: uuid.uuid) { combine(bytes: $0) }
    }

    /// The hash of one string, for the callers that have nothing else to mix.
    public static func hash(_ string: String) -> UInt64 {
        var hasher = Self()
        hasher.combine(string)
        return hasher.value
    }
}
