//
//  SeededGenerator.swift
//  OpenTrailsSharedTests
//
//  The projection tests sweep tens of thousands of random coordinates per
//  zoom level. Unseeded, a disagreement between `Mercator` and the formulas it
//  replaced is reported at a latitude nobody can generate again — which for a
//  test whose whole job is to catch a discrepancy of a few ulps is most of its
//  value gone.
//
//  Deliberately duplicated in `OpenTrailsTests` rather than shipped from the
//  package: this is test scaffolding, and the package's product is what the
//  app and the widget link against.
//

import Foundation

/// A deterministic `RandomNumberGenerator` (SplitMix64). Override the seed
/// with `OPENTRAILS_TEST_SEED` in the environment to reproduce a failure; the
/// tests quote the seed they ran with.
struct SeededGenerator: RandomNumberGenerator {
    static let defaultSeed: UInt64 = ProcessInfo.processInfo.environment["OPENTRAILS_TEST_SEED"]
        .flatMap(UInt64.init) ?? 0x4F70_656E_5472_6169

    let seed: UInt64
    private var state: UInt64

    init(seed: UInt64 = defaultSeed) {
        self.seed = seed
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
