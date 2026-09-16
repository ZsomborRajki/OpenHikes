//
//  ElevationDeadbandTests.swift
//  OpenHikesTests
//
//  "Elevation deadband", split out of HikeStatisticsTests.swift so that a
//  file declares one @Suite. That file's header still holds the context the
//  two share.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import SwiftData
import Testing

/// ``ElevationAccumulator`` is the one place "climbed" is defined, for the
/// detail stats, the widget snapshot and a live recording alike, so its
/// deadband is tested here directly rather than only through a route.
///
/// The property that matters is asymmetry: noise is symmetric, but summing
/// only the positive deltas is not, so without a deadband jitter integrates
/// into climb without bound and the error grows with the point count rather
/// than with the noise.
@Suite("Elevation deadband")
struct ElevationDeadbandTests {
    private static func gain(
        _ elevations: [Double],
        threshold: Double = ElevationAccumulator.reversalThresholdMeters
    ) -> ElevationAccumulator {
        var accumulator = ElevationAccumulator(reversalThresholdMeters: threshold)
        for elevation in elevations { accumulator.record(elevation) }
        return accumulator
    }

    @Test("terrain larger than the deadband is counted exactly as before")
    func realTerrainIsUnchanged() {
        let accumulator = Self.gain([100, 150, 220, 180, 260, 240])
        #expect(accumulator.gainMeters == 200)
        #expect(accumulator.lossMeters == 60)
    }

    /// The regression this exists for. Fails against the previous
    /// implementation, which reported ~500 m of climb for this input.
    @Test("jitter around one elevation is not climb")
    func jitterIsNotClimb() {
        let elevations = (0..<1000).map { idx in
            600 + (idx.isMultiple(of: 2) ? 1.0 : -1.0)
        }
        let accumulator = Self.gain(elevations)
        #expect(accumulator.gainMeters <= 2)
        #expect(accumulator.lossMeters <= 2)
    }

    /// The error must not scale with how long the walk was. Ten times the
    /// points of the same noise must not give ten times the climb — that is
    /// the difference between an overstatement and a fiction.
    @Test("the noise floor does not grow with the number of points")
    func noiseDoesNotAccumulate() {
        var generator = SeededGenerator()
        var short = ElevationAccumulator()
        var long = ElevationAccumulator()
        for idx in 0..<20_000 {
            let elevation = 600 + Double.random(in: -1.5...1.5, using: &generator)
            if idx < 2000 { short.record(elevation) }
            long.record(elevation)
        }
        #expect(long.gainMeters < short.gainMeters + 5, "seed \(generator.seed)")
    }

    @Test("a monotonic climb is reported in full")
    func monotonicClimb() {
        let accumulator = Self.gain((0..<1000).map { 500 + Double($0) })
        #expect(accumulator.gainMeters == 999)
        #expect(accumulator.lossMeters == 0)
    }

    /// A dip smaller than the deadband is weather or a footstep, not a
    /// descent followed by a second climb. Counting it as one would add the
    /// dip to the loss and re-add it to the gain.
    @Test("a dip shorter than the deadband does not split a climb")
    func shallowDipDoesNotSplitAClimb() {
        let accumulator = Self.gain([500, 520, 518, 540])
        #expect(accumulator.gainMeters == 40)
        #expect(accumulator.lossMeters == 0)
    }

    /// When a reversal does commit, what it commits is the run's peak — not
    /// the last reading before the turn, which would silently discard the
    /// summit.
    @Test("a committed climb is measured to its peak")
    func climbIsMeasuredToItsPeak() {
        let accumulator = Self.gain([500, 600, 599, 590])
        #expect(accumulator.gainMeters == 100)
        #expect(accumulator.lossMeters == 10)
    }

    /// A recording reads this while the hiker is still climbing. Withholding
    /// the run in progress until it reverses would show a total that freezes
    /// on the way up and jumps at the top.
    @Test("a climb in progress counts before it reverses")
    func climbInProgressCountsImmediately() {
        let accumulator = Self.gain([500, 510, 520])
        #expect(accumulator.gainMeters == 20)
    }

    @Test("descent mirrors ascent")
    func descentMirrorsAscent() {
        let accumulator = Self.gain([900, 800, 802, 750])
        #expect(accumulator.lossMeters == 150)
        #expect(accumulator.gainMeters == 0)
    }

    /// `<ele>nan</ele>` parses to a `Double` like any other height, and NaN
    /// loses every comparison — so one of them reaching `minimumMeters` and
    /// `maximumMeters` would not corrupt its own reading, it would replace
    /// the extremes of the whole route with itself and leave every total
    /// derived from them meaningless.
    @Test("a height that isn't a number is skipped like a missing one")
    func nonFiniteHeightsAreSkipped() throws {
        let accumulator = Self.gain([.nan, 500, .infinity, 600, -.infinity, 550])

        #expect(accumulator.count == 3)
        #expect(try #require(accumulator.minimumMeters) == 500)
        #expect(try #require(accumulator.maximumMeters) == 600)
        #expect(accumulator.gainMeters == 100)
        #expect(accumulator.lossMeters == 50)
    }

    /// And a route with nothing but such heights has to look like a route
    /// with no heights at all, rather than one whose extremes are NaN.
    @Test("a route of nothing but non-numbers has no elevation to report")
    func allNonFiniteHeightsReadAsNoHeights() {
        let accumulator = Self.gain([.nan, .infinity, -.infinity])

        #expect(accumulator.count == 0)
        #expect(accumulator.minimumMeters == nil)
        #expect(accumulator.maximumMeters == nil)
        #expect(!accumulator.hasChange)
    }

    @Test(
        "a reversal counts once it reaches the deadband, not before",
        arguments: [(2.9, 0.0), (3.0, 3.0)]
    )
    func reversalBoundary(drop: Double, expectedLoss: Double) {
        let accumulator = Self.gain([500, 510, 510 - drop], threshold: 3)
        #expect(accumulator.gainMeters == 10)
        #expect(accumulator.lossMeters == expectedLoss)
    }

    /// Pins the mutation: with the deadband set to zero the accumulator is
    /// the old one, and the noise test above stops holding. A test that
    /// passes against the unfixed code is not evidence.
    @Test("a zero deadband restores the behaviour this replaced")
    func zeroThresholdRestoresTheOldBehaviour() {
        let elevations = (0..<1000).map { idx in
            600 + (idx.isMultiple(of: 2) ? 1.0 : -1.0)
        }
        let accumulator = Self.gain(elevations, threshold: 0)
        #expect(accumulator.gainMeters > 900)
    }
}
