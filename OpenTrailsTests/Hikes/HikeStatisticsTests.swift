//
//  HikeStatisticsTests.swift
//  OpenTrailsTests
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
@testable import OpenTrails
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

    /// A standing rest is not a speed sample: segments with no elapsed time
    /// (or no timestamp on either end) are skipped, not treated as instant.
    @Test("max speed skips segments with no elapsed time")
    func maxSpeedSkipsUntimedSegments() throws {
        let start = Date(timeIntervalSince1970: 1_750_000_000)
        let route = [
            RouteCoordinate(latitude: 47.630, longitude: 12.86, timestamp: start),
            RouteCoordinate(latitude: 47.631, longitude: 12.86),                                    // no stamp
            RouteCoordinate(latitude: 47.632, longitude: 12.86, timestamp: start),                  // no elapsed time
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
