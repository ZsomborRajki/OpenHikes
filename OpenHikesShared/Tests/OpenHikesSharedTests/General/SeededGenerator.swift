//
//  SeededGenerator.swift
//  OpenHikesSharedTests
//
//  The projection tests sweep tens of thousands of random coordinates per
//  zoom level. Unseeded, a disagreement between `Mercator` and the formulas it
//  replaced is reported at a latitude nobody can generate again — which for a
//  test whose whole job is to catch a discrepancy of a few ulps is most of its
//  value gone.
//
//  Deliberately duplicated in `OpenHikesTests` rather than shipped from the
//  package: this is test scaffolding, and the package's product is what the
//  app and the widget link against.
//

import Foundation

/// A deterministic `RandomNumberGenerator` (SplitMix64). Override the seed
/// with `OPENHIKES_TEST_SEED` in the environment to reproduce a failure; the
/// tests quote the seed they ran with.
struct SeededGenerator: RandomNumberGenerator {
    // "OpenTrai" encoded as a UInt64 — a memorable, reproducible fallback seed
    private static let fallbackSeed: UInt64 = 0x4F70_656E_5472_6169
    static let defaultSeed: UInt64 = ProcessInfo.processInfo.environment["OPENHIKES_TEST_SEED"]
        .flatMap(UInt64.init) ?? fallbackSeed

    let seed: UInt64
    private var state: UInt64

    init(seed: UInt64 = defaultSeed) {
        self.seed = seed
        state = seed
    }

    // SplitMix64 algorithm constants
    private static let goldenGamma: UInt64 = 0x9E37_79B9_7F4A_7C15
    private static let mixConstant1: UInt64 = 0xBF58_476D_1CE4_E5B9
    private static let mixConstant2: UInt64 = 0x94D0_49BB_1331_11EB
    private static let mixShift1: UInt64 = 30
    private static let mixShift2: UInt64 = 27
    private static let mixShift3: UInt64 = 31

    mutating func next() -> UInt64 {
        state &+= Self.goldenGamma
        var z = state
        z = (z ^ (z >> Self.mixShift1)) &* Self.mixConstant1
        z = (z ^ (z >> Self.mixShift2)) &* Self.mixConstant2
        return z ^ (z >> Self.mixShift3)
    }
}
