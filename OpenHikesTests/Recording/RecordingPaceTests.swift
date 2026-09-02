//
//  RecordingPaceTests.swift
//  OpenHikesTests
//
//  The two figures a live recording gained beside its distance: how long the
//  walker has actually been walking, and how fast they are going *now* rather
//  than on average since breakfast.
//
//  Both are read off ``RecordingDistanceAccumulator`` because that is the one
//  place every accepted fix passes through exactly once, and both are driven
//  here by hand-built points for the reason `LiveMatchWindowTests` gives: what
//  is being pinned is arithmetic over timestamps, and a delivered fix cannot
//  say that a sample exactly on a window boundary is on the inside of it.
//

import Foundation
@testable import OpenHikes
import Testing

@Suite("Recording pace and moving time")
struct RecordingPaceTests {
    private let start = Date(timeIntervalSince1970: 1_750_000_000)

    /// Metres north of a fixed origin, which keeps every fixture below a
    /// distance rather than a pair of coordinates.
    private func point(
        metersNorth: Double,
        at offset: TimeInterval,
        flags: RecordingPointFlags = []
    ) -> RecordingPoint {
        RecordingPoint(
            latitude: 47.63 + metersNorth / 111_000,
            longitude: 12.86,
            timestamp: start.addingTimeInterval(offset),
            horizontalAccuracy: 8,
            flags: flags
        )
    }

    /// Walks north at a steady `metersPerSecond`, one fix every ten seconds.
    private func walk(
        _ accumulator: inout RecordingDistanceAccumulator,
        metersPerSecond: Double,
        seconds: TimeInterval,
        from offset: TimeInterval = 0,
        startingAt metersNorth: Double = 0
    ) {
        for step in stride(from: 0.0, through: seconds, by: 10) {
            accumulator.append(
                point(
                    metersNorth: metersNorth + step * metersPerSecond,
                    at: offset + step
                )
            )
        }
    }

    // MARK: Moving time

    /// The headline claim: standing still stops the moving clock, and it stops
    /// it by the same rule the *saved* hike's figure uses. A walker who
    /// watched this tick and then opened the saved hike to a different number
    /// would have no way to tell which one was the lie.
    @Test("standing still stops the moving clock but not the elapsed one")
    func stationaryTimeIsNotMovingTime() {
        var accumulator = RecordingDistanceAccumulator()
        walk(&accumulator, metersPerSecond: 1.4, seconds: 300)
        let movingWhileWalking = accumulator.movingSeconds

        // Ten minutes at the viewpoint: fixes keep arriving, the walker does
        // not move.
        for step in stride(from: 310.0, through: 900, by: 10) {
            accumulator.append(point(metersNorth: 420, at: step))
        }

        #expect(movingWhileWalking > 250)
        #expect(accumulator.isStationary)
        // The stop added at most one stationary interval's worth of credit —
        // the window has to fill before it can be called standing still — and
        // certainly not the ten minutes it lasted.
        #expect(
            accumulator.movingSeconds
                < movingWhileWalking
                + RecordingDistanceAccumulator.stationaryInterval
        )
    }

    /// A pause is not a slow stretch of walking. The gap it opens can be
    /// hours, and booking it would put a walk's moving time above its elapsed
    /// time — a figure that is not merely wrong but impossible.
    @Test("a pause is not booked as walking when the recording resumes")
    func resumingDoesNotBookThePause() {
        var accumulator = RecordingDistanceAccumulator()
        walk(&accumulator, metersPerSecond: 1.4, seconds: 300)
        let beforePause = accumulator.movingSeconds

        // An hour in the pub, then a resume a kilometre down the trail.
        accumulator.append(
            point(metersNorth: 1420, at: 3900, flags: [.resumed])
        )
        walk(
            &accumulator,
            metersPerSecond: 1.4,
            seconds: 300,
            from: 3910,
            startingAt: 1420
        )

        #expect(accumulator.movingSeconds > beforePause)
        #expect(accumulator.movingSeconds < beforePause + 400)
    }

    // MARK: Live speed

    /// Below the minimum span there is no figure rather than a jumpy one,
    /// which is also what the first minute of every walk gets.
    @Test("a window shorter than the minimum span reports no live speed")
    func shortWindowHasNoLiveSpeed() {
        var accumulator = RecordingDistanceAccumulator()
        walk(
            &accumulator,
            metersPerSecond: 1.4,
            seconds: RecordingDistanceAccumulator.minimumRecentSpeedSpan - 20
        )

        #expect(accumulator.recentSpeedMetersPerSecond == nil)
    }

    @Test("a steady walk reports the speed it is actually walking")
    func steadyWalkReportsItsSpeed() throws {
        var accumulator = RecordingDistanceAccumulator()
        walk(&accumulator, metersPerSecond: 1.4, seconds: 600)

        let speed = try #require(accumulator.recentSpeedMetersPerSecond)
        #expect(abs(speed - 1.4) < 0.05)
    }

    /// The whole reason a live speed exists. An hour of strolling followed by
    /// a fast last few minutes leaves the average almost where it was, and the
    /// walker wants to know what they are doing now.
    @Test("the live speed follows a change of pace the average cannot")
    func liveSpeedLeadsTheAverage() throws {
        var accumulator = RecordingDistanceAccumulator()
        walk(&accumulator, metersPerSecond: 0.8, seconds: 3600)
        let averageWhileStrolling = try #require(
            accumulator.averageSpeedMetersPerSecond
        )

        walk(
            &accumulator,
            metersPerSecond: 2.0,
            seconds: 400,
            from: 3610,
            startingAt: 3600 * 0.8
        )

        let live = try #require(accumulator.recentSpeedMetersPerSecond)
        let average = try #require(accumulator.averageSpeedMetersPerSecond)
        #expect(abs(live - 2.0) < 0.1)
        // The average barely noticed: an hour of ballast against six minutes
        // of news.
        #expect(average - averageWhileStrolling < 0.15)
    }

    /// The window is a window. A walk that has been going for hours is
    /// measured over the last few minutes of it, not over all of it, which is
    /// what stops this from slowly becoming a second average.
    @Test("the live speed forgets the far side of its window")
    func liveSpeedForgetsOlderWalking() throws {
        var accumulator = RecordingDistanceAccumulator()
        walk(&accumulator, metersPerSecond: 2.0, seconds: 1800)
        walk(
            &accumulator,
            metersPerSecond: 0.7,
            seconds: RecordingDistanceAccumulator.recentSpeedWindow * 2,
            from: 1810,
            startingAt: 1800 * 2.0
        )

        let speed = try #require(accumulator.recentSpeedMetersPerSecond)
        #expect(abs(speed - 0.7) < 0.05)
    }

    /// A stationary window hands back the wander it accumulated, which leaves
    /// the newest distance total *below* one taken minutes earlier. The
    /// subtraction that produces the live speed then runs negative, and a
    /// negative speed on a stat tile is worse than a wrong one — it is not a
    /// speed at all.
    @Test("a retracted distance reports a standstill, not a negative speed")
    func retractedDistanceCannotGoNegative() throws {
        var accumulator = RecordingDistanceAccumulator()
        walk(&accumulator, metersPerSecond: 1.4, seconds: 200)
        // Ten minutes of GPS jitter around one spot, which the accumulator
        // eventually calls standing still and retracts.
        for step in stride(from: 210.0, through: 800, by: 10) {
            let jitter = Double((Int(step / 10) % 3) - 1) * 3
            accumulator.append(point(metersNorth: 280 + jitter, at: step))
        }

        let speed = try #require(accumulator.recentSpeedMetersPerSecond)
        #expect(accumulator.isStationary)
        #expect(speed >= 0)
        #expect(speed < 0.1)
    }

    /// `RecordingFixPolicy` refuses a reordered pair live, so the path that
    /// can still deliver one is a journal replayed after a crash. Taking it as
    /// the newest sample would anchor the window on a timestamp in the future
    /// and divide by a span running backwards.
    @Test("a point that does not advance the clock cannot anchor the window")
    func reorderedPointDoesNotAnchorTheWindow() throws {
        var accumulator = RecordingDistanceAccumulator()
        walk(&accumulator, metersPerSecond: 1.4, seconds: 300)
        let before = try #require(accumulator.recentSpeedMetersPerSecond)

        accumulator.append(point(metersNorth: 420, at: 100))

        let after = try #require(accumulator.recentSpeedMetersPerSecond)
        #expect(after == before)
    }
}
