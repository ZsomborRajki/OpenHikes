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
import OpenHikesData
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

    /// A GPX whose stamps only start partway in used to divide the whole
    /// route by the part of the walk that carries a clock. Here three of the
    /// four legs are untimed, so the naive number is four times the pace the
    /// timed leg was actually walked at.
    @Test("leading untimed points don't inflate the average speed")
    func averageSpeedWithLeadingUntimedPoints() throws {
        let start = Date(timeIntervalSince1970: 1_750_000_000)
        // Four legs of ~111 m; the clock covers the last one, at ~1 m/s.
        let route = [
            RouteCoordinate(latitude: 47.630, longitude: 12.86),
            RouteCoordinate(latitude: 47.631, longitude: 12.86),
            RouteCoordinate(latitude: 47.632, longitude: 12.86),
            RouteCoordinate(latitude: 47.633, longitude: 12.86, timestamp: start),
            RouteCoordinate(latitude: 47.634, longitude: 12.86, timestamp: start.addingTimeInterval(111)),
        ]
        let stats = Fixture.hike(in: context, route: route).routeStatistics
        let timedMeters = RouteGeometry.distanceMeters(
            from: route[3].clCoordinate,
            to: route[4].clCoordinate
        )
        let speed = try #require(stats.averageSpeed).converted(to: .metersPerSecond).value
        #expect(try #require(stats.duration) == 111)
        #expect(
            abs(speed - timedMeters / 111) < 1e-6,
            """
            \(speed) m/s over the leg the clock covers, which was walked at \
            \(timedMeters / 111) m/s. Dividing the whole route by the timed \
            leg's clock gives ~4x that.
            """
        )
        // Both rows are the one distance seen through two clocks, so the
        // moving row takes the same cut. Nothing here is a stop.
        let moving = try #require(stats.movingAverageSpeed).converted(to: .metersPerSecond).value
        #expect(abs(moving - speed) < 1e-6)
    }

    /// The mirror image: a recorder whose clock stops before the walk does.
    @Test("trailing untimed points don't inflate the average speed")
    func averageSpeedWithTrailingUntimedPoints() throws {
        let start = Date(timeIntervalSince1970: 1_750_000_000)
        let route = [
            RouteCoordinate(latitude: 47.630, longitude: 12.86, timestamp: start),
            RouteCoordinate(latitude: 47.631, longitude: 12.86, timestamp: start.addingTimeInterval(111)),
            RouteCoordinate(latitude: 47.632, longitude: 12.86),
            RouteCoordinate(latitude: 47.633, longitude: 12.86),
            RouteCoordinate(latitude: 47.634, longitude: 12.86),
        ]
        let stats = Fixture.hike(in: context, route: route).routeStatistics
        let timedMeters = RouteGeometry.distanceMeters(
            from: route[0].clCoordinate,
            to: route[1].clCoordinate
        )
        let speed = try #require(stats.averageSpeed).converted(to: .metersPerSecond).value
        #expect(abs(speed - timedMeters / 111) < 1e-6)
    }

    /// An interior gap is not a coverage gap: the elapsed clock spans the
    /// unstamped points as surely as the stamped ones, so the whole route
    /// still counts and the number is the one it has always been.
    @Test("untimed points in the middle still count toward the average speed")
    func averageSpeedWithInteriorUntimedPoints() throws {
        let start = Date(timeIntervalSince1970: 1_750_000_000)
        let route = [
            RouteCoordinate(latitude: 47.630, longitude: 12.86, timestamp: start),
            RouteCoordinate(latitude: 47.631, longitude: 12.86),
            RouteCoordinate(latitude: 47.632, longitude: 12.86),
            RouteCoordinate(latitude: 47.633, longitude: 12.86, timestamp: start.addingTimeInterval(333)),
        ]
        let hike = Fixture.hike(in: context, route: route)
        let stats = hike.routeStatistics
        let speed = try #require(stats.averageSpeed).converted(to: .metersPerSecond).value
        #expect(abs(speed - hike.distanceMeters / 333) < 1e-6)
    }

    /// Max speed is per-segment, so a single fast stretch has to surface even
    /// when the walk as a whole is slow.
    @Test("max speed finds the fastest single segment")
    func maxSpeed() throws {
        let start = Date(timeIntervalSince1970: 1_750_000_000)
        // ~111 m per 0.001° of latitude: 111 m in 30 s, then 111 m in 300 s.
        let route = [
            RouteCoordinate(latitude: 47.630, longitude: 12.86, timestamp: start),
            RouteCoordinate(latitude: 47.631, longitude: 12.86, timestamp: start.addingTimeInterval(30)),
            RouteCoordinate(latitude: 47.632, longitude: 12.86, timestamp: start.addingTimeInterval(330)),
        ]
        let stats = Fixture.hike(in: context, route: route).routeStatistics
        let fastest = try #require(stats.maxSpeed).converted(to: .metersPerSecond).value
        let average = try #require(stats.averageSpeed).converted(to: .metersPerSecond).value
        #expect(abs(fastest - 3.7) < 0.1)
        #expect(fastest > average)
    }

    /// An imported GPX is cleaned by nobody — ``RecordingFixPolicy`` only sees
    /// fixes this app recorded itself. One pair a second apart and a hundred
    /// metres wide is enough to report ~360 km/h as the walk's maximum, and it
    /// would be the largest figure in the stats grid.
    @Test("a segment nobody could have walked isn't the hike's fastest")
    func maxSpeedIgnoresImplausibleSegments() throws {
        let start = Date(timeIntervalSince1970: 1_750_000_000)
        let route = [
            RouteCoordinate(latitude: 47.630, longitude: 12.86, timestamp: start),
            // ~111 m in one second: a dropped fix reacquired somewhere else.
            RouteCoordinate(latitude: 47.631, longitude: 12.86, timestamp: start.addingTimeInterval(1)),
            RouteCoordinate(latitude: 47.632, longitude: 12.86, timestamp: start.addingTimeInterval(101)),
        ]
        let stats = Fixture.hike(in: context, route: route).routeStatistics
        let fastest = try #require(stats.maxSpeed).converted(to: .metersPerSecond).value

        #expect(fastest <= RecordingFixPolicy.maximumSpeed)
        // The surviving segment, reported as itself rather than capped at the
        // ceiling — a clamp would invent a second number that looks measured.
        #expect(abs(fastest - 1.11) < 0.1)
    }

    /// A track made entirely of implausible legs has no fastest segment to
    /// report, which is the same answer a walk with no clock gets. Better an
    /// absent tile than a confident wrong one.
    @Test("a route with nothing walkable in it reports no max speed")
    func maxSpeedAbsentWhenEverySegmentIsImplausible() {
        let start = Date(timeIntervalSince1970: 1_750_000_000)
        let route = (0..<4).map { idx in
            RouteCoordinate(
                latitude: 47.63 + Double(idx) * 0.001,
                longitude: 12.86,
                timestamp: start.addingTimeInterval(Double(idx))
            )
        }
        #expect(Fixture.hike(in: context, route: route).routeStatistics.maxSpeed == nil)
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

    /// The row's second line is the only place a hike's length and its date
    /// appear in the list, so both halves are pinned. A subtitle that dated
    /// every row with today, or lost its length entirely, still contains a
    /// "·" and is still longer than five characters.
    @Test("the list subtitle carries both a length and a date")
    func subtitle() {
        // Comfortably in the past, so "is this the hike's date or the day the
        // list was drawn?" can never be answered by coincidence.
        let recorded = Date(timeIntervalSince1970: 1_000_000_000)
        let hike = Fixture.hike(in: context) { $0.date = recorded }
        let halves = hike.subtitle.components(separatedBy: " · ")

        #expect(halves.count == 2)
        #expect(
            halves.first
                == hike.distance.formatted(.measurement(width: .abbreviated, usage: .road))
        )
        #expect(halves.last == recorded.formatted(date: .abbreviated, time: .omitted))
        #expect(halves.last != Date.now.formatted(date: .abbreviated, time: .omitted))
    }
}
