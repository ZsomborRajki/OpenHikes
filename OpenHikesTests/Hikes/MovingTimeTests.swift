//
//  MovingTimeTests.swift
//  OpenHikesTests
//
//  What "moving" means, and what the two average-speed rows promise.
//
//  The elapsed average divides a walk's distance by the whole clock, lunch
//  included, which is why a leisurely day out reports a pace nobody walked.
//  The moving average divides it by the part of that clock the walker was
//  actually going somewhere. Everything here is about where the boundary
//  between the two sits, so the fixtures are built in metres per second and
//  seconds rather than out of a recorded file.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import Testing

@Suite("Moving time")
struct MovingTimeTests {
    private static let start = Date(timeIntervalSince1970: 1_750_000_000)
    /// One degree of latitude, near enough for a fixture that only ever walks
    /// due north. Derived from the same mean radius ``RouteGeometry`` uses, so
    /// a leg asked for at 1.4 m/s measures back as 1.4 m/s.
    private static let metersPerDegreeLatitude = 2 * Double.pi * 6_371_008.8 / 360

    private struct Leg {
        let seconds: Int
        let metersPerSecond: Double
    }

    /// One point per second along a due-north line, so a leg's speed is
    /// exactly what it was asked for and the only thing under test is where
    /// the moving/stopped boundary falls.
    private static func walk(_ legs: [Leg]) -> [RouteCoordinate] {
        var points: [RouteCoordinate] = []
        var latitude = 47.63
        var second = 0
        points.append(
            RouteCoordinate(
                latitude: latitude,
                longitude: 12.86,
                timestamp: start
            )
        )
        for leg in legs {
            let step = leg.metersPerSecond / metersPerDegreeLatitude
            for _ in 0..<leg.seconds {
                latitude += step
                second += 1
                points.append(
                    RouteCoordinate(
                        latitude: latitude,
                        longitude: 12.86,
                        timestamp: start.addingTimeInterval(Double(second))
                    )
                )
            }
        }
        return points
    }

    /// A due-north line stamped with the seconds given, in the order given.
    /// Consecutive points are far enough apart that every window the rule can
    /// judge is a walk, so the only thing under test is the arithmetic on the
    /// clock.
    private static func walk(seconds: [Double]) -> [RouteCoordinate] {
        seconds.enumerated().map { index, second in
            RouteCoordinate(
                latitude: 47.63 + Double(index) * 140 / metersPerDegreeLatitude,
                longitude: 12.86,
                timestamp: start.addingTimeInterval(second)
            )
        }
    }

    private static func statistics(for route: [RouteCoordinate]) -> HikeRouteStatistics {
        var meters = 0.0
        for (previous, next) in zip(route, route.dropFirst()) {
            meters += RouteGeometry.distanceMeters(
                from: previous.clCoordinate,
                to: next.clCoordinate
            )
        }
        return HikeRouteStatistics(distanceMeters: meters, route: route)
    }

    private static let walkingSpeed = 1.4

    /// The case the second row exists for: ten minutes out, half an hour
    /// sitting down, ten minutes back. The elapsed average is dragged to a
    /// third of the pace actually walked.
    @Test("a long stop is left out of the moving clock")
    func aLunchStopIsNotWalking() throws {
        let stats = Self.statistics(
            for: Self.walk([
                Leg(seconds: 600, metersPerSecond: Self.walkingSpeed),
                Leg(seconds: 1800, metersPerSecond: 0),
                Leg(seconds: 600, metersPerSecond: Self.walkingSpeed),
            ])
        )
        let duration = try #require(stats.duration)
        let moving = try #require(stats.movingDuration)

        #expect(duration == 3000)
        // The two 600-second legs, give or take the window's own length: the
        // rule cannot see a stop until it has watched one for an interval, and
        // is equally slow to notice the walk resuming, so the two errors are
        // opposite and roughly cancel.
        #expect(
            abs(moving - 1200) <= RecordingDistanceAccumulator.stationaryInterval * 2,
            "expected about 1200 s of moving time, got \(moving)"
        )
        let elapsedAverage = try #require(stats.averageSpeed)
            .converted(to: .metersPerSecond).value
        let movingAverage = try #require(stats.movingAverageSpeed)
            .converted(to: .metersPerSecond).value
        #expect(abs(movingAverage - Self.walkingSpeed) < 0.15)
        #expect(movingAverage > elapsedAverage * 2)
    }

    /// The case a persisted pause exists for, and the one this rule cannot
    /// judge on its own: paused at one trailhead, driven to the next, resumed.
    /// The span is long *and* the displacement is large, which is precisely
    /// what walking looks like from here — so without the boundary the drive
    /// is booked as an hour of moving time.
    @Test("a pause is not moving time, however far the walker went during it")
    func aPauseIsNotMovingTime() throws {
        let walkedOut = Self.walk([Leg(seconds: 600, metersPerSecond: Self.walkingSpeed)])
        let lastPoint = try #require(walkedOut.last)
        let drivenLatitude = lastPoint.latitude + 5000 / Self.metersPerDegreeLatitude
        let resumeTime = Self.start.addingTimeInterval(600 + 3600)
        var route = walkedOut
        route.append(
            RouteCoordinate(
                latitude: drivenLatitude,
                longitude: 12.86,
                timestamp: resumeTime,
                boundary: .paused
            )
        )
        for second in 1...600 {
            route.append(
                RouteCoordinate(
                    latitude: drivenLatitude
                        + Double(second) * Self.walkingSpeed / Self.metersPerDegreeLatitude,
                    longitude: 12.86,
                    timestamp: resumeTime.addingTimeInterval(Double(second))
                )
            )
        }

        let moving = try #require(Self.statistics(for: route).movingDuration)
        #expect(
            abs(moving - 1200) <= RecordingDistanceAccumulator.stationaryInterval * 2,
            "expected about 1200 s of walking either side of the pause, got \(moving)"
        )

        // The same points with the boundary rubbed out — which is what every
        // hike recorded before it existed looks like, and what this is worth
        // measuring against.
        let flattened = route.map { point -> RouteCoordinate in
            var stripped = point
            stripped.boundary = nil
            return stripped
        }
        let flattenedMoving = try #require(Self.statistics(for: flattened).movingDuration)
        #expect(flattenedMoving > moving + 3000)
    }

    /// A walk with nothing to subtract has to report the same number twice.
    /// The presumption is what buys this: an unjudgeable window counts as
    /// movement, so the head of a route is not quietly deducted.
    @Test("a walk with no stops reports one number twice")
    func anUninterruptedWalkAgreesWithItself() throws {
        let stats = Self.statistics(
            for: Self.walk([Leg(seconds: 900, metersPerSecond: Self.walkingSpeed)])
        )
        let locale = Locale(identifier: "de_DE")
        let moving = try #require(stats.movingAverageSpeed)
        let overall = try #require(stats.averageSpeed)

        #expect(stats.movingDuration == stats.duration)
        #expect(moving == overall)
        #expect(HikeFormat.speed(moving, locale: locale) == HikeFormat.speed(overall, locale: locale))
    }

    /// Slow is not the same as stopped, and a rule that confused the two would
    /// inflate exactly the number a walker is most likely to quote. One metre
    /// per second is a plod, and it has to survive.
    @Test("a slow but steady walk is still walking")
    func aPlodCountsAsMovement() {
        let stats = Self.statistics(
            for: Self.walk([Leg(seconds: 900, metersPerSecond: 1)])
        )

        #expect(stats.movingDuration == stats.duration)
    }

    /// The moving clock can never run longer than the wall clock, whatever the
    /// route looks like. Stated separately because it is the one thing a
    /// reader of the two rows will assume without checking.
    @Test("moving time never exceeds elapsed time", arguments: [0.0, 0.3, 1.4, 3.0])
    func movingTimeIsBoundedByElapsed(metersPerSecond: Double) throws {
        let stats = Self.statistics(
            for: Self.walk([
                Leg(seconds: 300, metersPerSecond: metersPerSecond),
                Leg(seconds: 300, metersPerSecond: 0),
                Leg(seconds: 300, metersPerSecond: metersPerSecond),
            ])
        )
        let duration = try #require(stats.duration)

        #expect((stats.movingDuration ?? 0) <= duration)
    }

    /// A phone left running on a table walked nowhere. It is allowed the one
    /// window the rule was not able to judge and not a second more — the
    /// deliberate cost of presuming movement, bounded so it stays a rounding
    /// error rather than a claim.
    @Test("a recording that never moves books at most one unjudged window")
    func standingStillIsNotAWalk() {
        let stats = Self.statistics(
            for: Self.walk([Leg(seconds: 900, metersPerSecond: 0)])
        )

        #expect(
            (stats.movingDuration ?? 0)
                <= RecordingDistanceAccumulator.stationaryInterval + 1
        )
    }

    /// And when the points are sparse enough that even the first window can be
    /// judged — two fixes half an hour apart in the same spot, which is what a
    /// stationary recording actually produces once the distance filter widens
    /// — there is no moving time to report at all.
    @Test("two fixes in one place half an hour apart are not a walk")
    func aSparseStandstillHasNoMovingTime() {
        let route = [
            RouteCoordinate(latitude: 47.63, longitude: 12.86, timestamp: Self.start),
            RouteCoordinate(
                latitude: 47.63002,
                longitude: 12.86,
                timestamp: Self.start.addingTimeInterval(1800)
            ),
        ]
        let stats = Self.statistics(for: route)

        #expect(stats.duration == 1800)
        #expect(stats.movingDuration == nil)
        #expect(stats.movingAverageSpeed == nil)
    }

    @Test("a single point has neither clock")
    func aSinglePointHasNoDuration() {
        let stats = Self.statistics(
            for: [RouteCoordinate(latitude: 47.63, longitude: 12.86, timestamp: Self.start)]
        )

        #expect(stats.duration == nil)
        #expect(stats.movingDuration == nil)
        #expect(stats.movingAverageSpeed == nil)
    }

    /// Every point stamped with the same instant: a real shape, no clock. The
    /// moving average must be absent rather than a division by zero dressed up
    /// as a measurement.
    @Test("a route with no elapsed time has no moving average")
    func aZeroDurationRouteHasNoMovingAverage() {
        let route = (0..<50).map { step in
            RouteCoordinate(
                latitude: 47.63 + Double(step) * 1e-4,
                longitude: 12.86,
                timestamp: Self.start
            )
        }
        let stats = Self.statistics(for: route)

        #expect(stats.duration == nil)
        #expect(stats.movingDuration == nil)
        #expect(stats.movingAverageSpeed == nil)
    }

    /// A GPX with its points out of order. The offending sample used to be
    /// refused as an interval and kept as a reference, so the sample after it
    /// was measured from a point 50 seconds in the past: `0, 100, 50, 200`
    /// booked 250 seconds of walking inside a 200-second hike.
    @Test("a timestamp out of order cannot be double-counted")
    func aReversedTimestampIsNotAReference() throws {
        let stats = Self.statistics(for: Self.walk(seconds: [0, 100, 50, 200]))
        let duration = try #require(stats.duration)
        let moving = try #require(stats.movingDuration)

        #expect(duration == 200)
        #expect(moving <= duration)
        // Every interval the route can support, measured once: 0→100 and
        // 100→200, with the sample between them ignored entirely.
        #expect(moving == 200)
    }

    /// And when the reversal is the last thing in the file, the hike ends
    /// before the furthest point of its own clock. There is less elapsed time
    /// to report than there was movement, and the smaller number wins.
    @Test("a route that ends early reports no more movement than clock")
    func aRouteEndingBackwardsIsBoundedByItsClock() throws {
        let stats = Self.statistics(for: Self.walk(seconds: [0, 100, 50]))
        let duration = try #require(stats.duration)

        #expect(duration == 50)
        #expect((stats.movingDuration ?? 0) <= duration)
    }

    /// A hike the walker brought with them carries timestamps and coordinates
    /// and nothing else — no Core Motion verdict, no recorder flags. The rule
    /// is built from what both kinds of route have, so the same geometry has
    /// to answer identically whether or not the extra field is set.
    @Test("an imported route is judged the same as a recorded one")
    func motionFlagsChangeNothing() throws {
        let legs = [
            Leg(seconds: 300, metersPerSecond: Self.walkingSpeed),
            Leg(seconds: 600, metersPerSecond: 0),
            Leg(seconds: 300, metersPerSecond: Self.walkingSpeed),
        ]
        let imported = Self.walk(legs)
        let recorded = imported.map { point in
            var copy = point
            copy.motion = .nonPedestrian
            return copy
        }

        let importedMoving = try #require(Self.statistics(for: imported).movingDuration)
        let recordedMoving = try #require(Self.statistics(for: recorded).movingDuration)
        #expect(importedMoving == recordedMoving)
    }

    /// The rule is the recording path's own, shared rather than restated. If
    /// somebody retunes what standing still means for a live recording, the
    /// number a saved hike reports has to move with it.
    @Test("the stillness rate is the recording path's, not a second one")
    func theRateComesFromTheRecordingPolicy() {
        #expect(
            MovingTimeAccumulator.stillnessRate
                == RecordingDistanceAccumulator.stationaryNetDisplacement
                    / RecordingDistanceAccumulator.stationaryInterval
        )
        // Corroborated independently by the fix policy: the smallest
        // displacement it will accept, over the longest it will wait for one.
        #expect(
            MovingTimeAccumulator.stillnessRate
                == RecordingFixPolicy.minimumDisplacement / RecordingFixPolicy.maximumInterval
        )
    }
}
