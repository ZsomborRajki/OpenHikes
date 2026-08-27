//
//  HikeStatisticsTests.swift
//  OpenHikesTests
//
//  Every tile in the hike detail view's stats grid comes from
//  ``HikeRouteStatistics``. It's computed from the raw track points, which —
//  coming from arbitrary GPX files — are routinely missing elevation, missing
//  timestamps, or carrying timestamps that don't advance. Each stat has to
//  either produce a defensible number or decline to appear at all; there is
//  no third option, because a wrong number looks exactly like a right one.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import SwiftData
import Testing

@Suite("Hike statistics")
struct HikeStatisticsTests {
    private let context: ModelContext

    init() throws {
        context = try Fixture.modelContext()
    }

    // MARK: Elevation

    /// The fixture climbs 100→150→220, drops to 180, climbs to 260, drops to
    /// 240: +50 +70 +80 of climb and −40 −20 of descent, counted as the sum
    /// of the per-step deltas rather than the difference between the
    /// extremes (which would report 160 of climb and none of the descent).
    @Test("gain and loss accumulate every step, not just the extremes")
    func elevationGainAndLoss() throws {
        let stats = Fixture.hike(in: context).routeStatistics
        #expect(try #require(stats.elevationGain).converted(to: .meters).value == 200)
        #expect(try #require(stats.elevationLoss).converted(to: .meters).value == 60)
        #expect(try #require(stats.maxElevation).converted(to: .meters).value == 260)
        #expect(try #require(stats.minElevation).converted(to: .meters).value == 100)
    }

    @Test("a route without elevation reports no elevation stats")
    func elevationAbsent() {
        let route = [
            RouteCoordinate(latitude: 47.63, longitude: 12.86),
            RouteCoordinate(latitude: 47.64, longitude: 12.86),
        ]
        let stats = Fixture.hike(in: context, route: route).routeStatistics
        #expect(stats.elevationGain == nil)
        #expect(stats.elevationLoss == nil)
        #expect(stats.maxElevation == nil)
        #expect(stats.minElevation == nil)
    }

    /// One elevation reading is a measurement, not a profile — there's no
    /// delta to accumulate, so gain/loss stay absent while max/min don't.
    @Test("a single elevation reading gives extremes but no gain or loss")
    func elevationSinglePoint() {
        let route = [
            RouteCoordinate(latitude: 47.63, longitude: 12.86, elevation: 600),
            RouteCoordinate(latitude: 47.64, longitude: 12.86),
        ]
        let stats = Fixture.hike(in: context, route: route).routeStatistics
        #expect(stats.elevationGain == nil)
        #expect(stats.elevationLoss == nil)
        #expect(stats.maxElevation?.value == 600)
    }

    /// A flat stretch is neither climb nor descent — deltas of exactly zero
    /// must not land in either total.
    @Test("flat sections count as neither climb nor descent")
    func flatSections() throws {
        let route = (0..<4).map { idx in
            RouteCoordinate(latitude: 47.63 + Double(idx) * 0.001, longitude: 12.86, elevation: 600)
        }
        let stats = Fixture.hike(in: context, route: route).routeStatistics
        #expect(try #require(stats.elevationGain).value == 0)
        #expect(try #require(stats.elevationLoss).value == 0)
    }

    /// The user-visible end of the deadband. An imported GPX recorded by a
    /// GPS-only device carries altitude that wanders by metres between
    /// consecutive points; before the deadband those wanders were summed as
    /// climb, so a walk along a level valley floor reported hundreds of
    /// metres of ascent in the stats grid.
    @Test("a level route recorded with noisy altitude reports almost no climb")
    func noisyLevelRouteReportsNoClimb() throws {
        var generator = SeededGenerator()
        let route = (0..<2000).map { idx in
            RouteCoordinate(
                latitude: 47.63 + Double(idx) * 0.00001,
                longitude: 12.86,
                elevation: 600 + Double.random(in: -1.5...1.5, using: &generator)
            )
        }
        let stats = Fixture.hike(in: context, route: route).routeStatistics
        let gain = try #require(stats.elevationGain).converted(to: .meters).value
        #expect(
            gain < 10,
            """
            2,000 points of ±1.5 m noise around one elevation reported \
            \(Int(gain)) m of climb (seed \(generator.seed)). Summing every \
            positive delta gives ~965 m here.
            """
        )
    }

    // MARK: Time

    @Test("duration spans the first and last timestamped points")
    func duration() throws {
        let stats = Fixture.hike(in: context).routeStatistics
        #expect(try #require(stats.duration) == 5 * 60)
        #expect(stats.startDate == Fixture.ridgeRoute.first?.timestamp)
        #expect(stats.endDate == Fixture.ridgeRoute.last?.timestamp)
    }

    @Test("an untimed route has no duration and no speeds")
    func durationAbsent() {
        let route = [
            RouteCoordinate(latitude: 47.63, longitude: 12.86, elevation: 600),
            RouteCoordinate(latitude: 47.64, longitude: 12.86, elevation: 610),
        ]
        let stats = Fixture.hike(in: context, route: route).routeStatistics
        #expect(stats.duration == nil)
        #expect(stats.averageSpeed == nil)
        #expect(stats.maxSpeed == nil)
    }

    /// Some exporters stamp every point with the same instant. That's not a
    /// zero-length hike, it's a hike with no usable clock — and dividing by
    /// it would produce an infinite speed.
    @Test("identical timestamps yield no duration rather than a division by zero")
    func durationZeroSpan() {
        let stamp = Date(timeIntervalSince1970: 1_750_000_000)
        let route = (0..<3).map { idx in
            RouteCoordinate(latitude: 47.63 + Double(idx) * 0.001, longitude: 12.86, elevation: 600, timestamp: stamp)
        }
        let stats = Fixture.hike(in: context, route: route).routeStatistics
        #expect(stats.duration == nil)
        #expect(stats.averageSpeed == nil)
        #expect(stats.maxSpeed == nil)
    }

    // MARK: Speed

    @Test("average speed is the stored length over the elapsed time")
    func averageSpeed() throws {
        let hike = Fixture.hike(in: context)
        let stats = hike.routeStatistics
        let speed = try #require(stats.averageSpeed).converted(to: .metersPerSecond).value
        let expected = hike.distanceMeters / (try #require(stats.duration))
        #expect(abs(speed - expected) < 1e-9)
    }

    /// Max speed is per-segment, so a single fast stretch has to surface even
    /// when the walk as a whole is slow.
    @Test("max speed finds the fastest single segment")
    func maxSpeed() throws {
        let start = Date(timeIntervalSince1970: 1_750_000_000)
        // ~111 m per 0.001° of latitude: 111 m in 10 s, then 111 m in 100 s.
        let route = [
            RouteCoordinate(latitude: 47.630, longitude: 12.86, timestamp: start),
            RouteCoordinate(latitude: 47.631, longitude: 12.86, timestamp: start.addingTimeInterval(10)),
            RouteCoordinate(latitude: 47.632, longitude: 12.86, timestamp: start.addingTimeInterval(110)),
        ]
        let stats = Fixture.hike(in: context, route: route).routeStatistics
        let fastest = try #require(stats.maxSpeed).converted(to: .metersPerSecond).value
        let average = try #require(stats.averageSpeed).converted(to: .metersPerSecond).value
        #expect(abs(fastest - 11.1) < 0.5)
        #expect(fastest > average)
    }

    /// A segment is a speed sample only when both its ends carry a timestamp.
    /// Here the first two segments have an unstamped end, so the fastest is
    /// the last segment alone.
    @Test("max speed skips segments with no elapsed time")
    func maxSpeedSkipsUntimedSegments() throws {
        let start = Date(timeIntervalSince1970: 1_750_000_000)
        let route = [
            RouteCoordinate(latitude: 47.630, longitude: 12.86, timestamp: start),
            RouteCoordinate(latitude: 47.631, longitude: 12.86),                                    // no stamp
            RouteCoordinate(latitude: 47.632, longitude: 12.86, timestamp: start),                  // no stamp before
            RouteCoordinate(latitude: 47.633, longitude: 12.86, timestamp: start.addingTimeInterval(100)),
        ]
        let stats = Fixture.hike(in: context, route: route).routeStatistics
        let fastest = try #require(stats.maxSpeed).converted(to: .metersPerSecond).value
        #expect(fastest.isFinite)
        #expect(abs(fastest - 1.11) < 0.1)
    }

    /// Timestamps that advance while the position doesn't (a paused
    /// recording) mean there is no fastest segment to report.
    @Test("standing still reports no max speed at all")
    func maxSpeedStationary() {
        let start = Date(timeIntervalSince1970: 1_750_000_000)
        let route = (0..<3).map { idx in
            RouteCoordinate(latitude: 47.63, longitude: 12.86, timestamp: start.addingTimeInterval(Double(idx) * 60))
        }
        #expect(Fixture.hike(in: context, route: route).routeStatistics.maxSpeed == nil)
    }

    // MARK: Presentation

    @Test("point count and coordinates mirror the stored route")
    func routeAccessors() {
        let hike = Fixture.hike(in: context)
        #expect(hike.pointCount == Fixture.ridgeRoute.count)
        #expect(hike.coordinates.count == Fixture.ridgeRoute.count)
        #expect(hike.distance.unit == .meters)
        #expect(hike.distance.value == hike.distanceMeters)
    }

    @Test("the list subtitle carries both a length and a date")
    func subtitle() {
        let hike = Fixture.hike(in: context)
        let subtitle = hike.subtitle
        #expect(subtitle.contains("·"))
        #expect(subtitle.count > 5)
    }
}

@Suite("Stat formatting")
struct HikeFormatTests {
    /// Under an hour the interesting unit is seconds; over it, nobody wants
    /// to read "72 min 13 sec".
    @Test("duration switches units at the hour mark")
    func duration() {
        let short = HikeFormat.duration(90)
        #expect(short.contains("1"))
        #expect(!short.lowercased().contains("h"))

        let long = HikeFormat.duration(3600 + 25 * 60)
        #expect(long.lowercased().contains("h"))
        #expect(long.contains("25"))
    }

    /// Elevations are whole metres — a stat tile reading "217.4382 m" is
    /// false precision on data this noisy.
    @Test("lengths are rounded to whole units and keep the unit they were given")
    func length() {
        let text = HikeFormat.length(Measurement(value: 217.4382, unit: .meters))
        #expect(text.contains("217"))
        #expect(!text.contains("."))
        #expect(!text.contains("218"))
    }

    /// Speeds arrive in metres per second and are read in km/h.
    @Test("speeds are converted to km/h with one decimal")
    func speed() {
        let text = HikeFormat.speed(Measurement(value: 10, unit: .metersPerSecond))
        #expect(text.contains("36"))
        #expect(text.contains("km/h"))
    }
}

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

    /// A recording reads this while the walker is still climbing. Withholding
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
