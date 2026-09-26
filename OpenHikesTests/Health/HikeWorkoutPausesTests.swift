//
//  HikeWorkoutPausesTests.swift
//  OpenHikesTests
//
//  When a workout was not walking, read off the line it carries. The
//  recorders' own suites own where that line comes from; this owns the rule
//  that turns it into pauses, and the one property everything else rests on:
//  the wall clock less the pauses is the moving time the hike shows.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import Testing

@Suite("Workout pauses")
struct HikeWorkoutPausesTests {
    private static let start = Date(timeIntervalSince1970: 1_757_000_000)

    private static func point(_ offset: TimeInterval?, resumes: Bool = false) -> RouteCoordinate {
        RouteCoordinate(
            latitude: 47.63,
            longitude: 12.86,
            timestamp: offset.map { start.addingTimeInterval($0) },
            boundary: resumes ? .paused : nil
        )
    }

    private static func interval(_ from: TimeInterval, _ to: TimeInterval) -> DateInterval {
        DateInterval(start: start.addingTimeInterval(from), end: start.addingTimeInterval(to))
    }

    @Test("an unbroken walk that ends on its last point has no pauses")
    func anUnbrokenWalkHasNoPauses() {
        let route = [Self.point(0), Self.point(60), Self.point(120)]
        let pauses = HikeWorkoutPauses.pauses(
            in: route,
            from: Self.start,
            to: Self.start.addingTimeInterval(120)
        )
        #expect(pauses.isEmpty)
    }

    /// The leg a resume opens is the pause, the same leg
    /// ``PreparedRecording/recordedSeconds`` leaves out — and so is the wait
    /// for a first fix, which that clock never counted either.
    @Test("the wait for a first fix, a pause and a stop while paused are each a pause")
    func everyUnrecordedStretchIsAPause() {
        let route = [Self.point(30), Self.point(90), Self.point(600, resumes: true), Self.point(700)]
        let pauses = HikeWorkoutPauses.pauses(
            in: route,
            from: Self.start,
            to: Self.start.addingTimeInterval(1000)
        )
        #expect(pauses == [Self.interval(0, 30), Self.interval(90, 600), Self.interval(700, 1000)])
        let active = 1000 - pauses.reduce(0) { $0 + $1.duration }
        #expect(active == 60 + 100)
    }

    /// A point with no time says nothing about when, and a route with none
    /// at all says nothing about pauses rather than that the walk was one.
    @Test("points with no timestamp are passed over")
    func untimedPointsArePassedOver() {
        let end = Self.start.addingTimeInterval(100)
        #expect(HikeWorkoutPauses.pauses(in: [Self.point(nil), Self.point(nil)], from: Self.start, to: end).isEmpty)
        let route = [Self.point(0), Self.point(nil), Self.point(100)]
        #expect(HikeWorkoutPauses.pauses(in: route, from: Self.start, to: end).isEmpty)
    }

    /// A fix from before Start — a cached one, say — is not inside the
    /// workout, so it cannot make a segment reach outside it.
    @Test("segments are clamped to the workout")
    func segmentsAreClampedToTheWorkout() {
        let route = [Self.point(-50), Self.point(40), Self.point(200, resumes: true), Self.point(260)]
        let pauses = HikeWorkoutPauses.pauses(
            in: route,
            from: Self.start,
            to: Self.start.addingTimeInterval(230)
        )
        #expect(pauses == [Self.interval(40, 200)])
    }

    @Test("the workout ends at Stop, or the last point if the line runs past it")
    func theEndCoversTheLine() {
        let route = [Self.point(0), Self.point(100), Self.point(nil)]
        let stop = Self.start.addingTimeInterval(500)
        #expect(HikeWorkoutPauses.end(stoppedAt: stop, startedAt: Self.start, route: route) == stop)
        #expect(
            HikeWorkoutPauses.end(stoppedAt: Self.start.addingTimeInterval(80), startedAt: Self.start, route: route)
                == Self.start.addingTimeInterval(100)
        )
        #expect(
            HikeWorkoutPauses.end(stoppedAt: nil, startedAt: Self.start, route: route)
                == Self.start.addingTimeInterval(100)
        )
        #expect(HikeWorkoutPauses.end(stoppedAt: nil, startedAt: Self.start, route: []) == Self.start)
    }
}
