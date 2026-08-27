//
//  LiveMatchWindowTests.swift
//  OpenHikesTests
//
//  `HikeRecorder.liveWindowRetainedStart(in:)` decides how much of a running
//  recording is handed to the live trail matcher, and it is bounded twice: by
//  a point count, and by a duration. Both bounds are exact — an index and a
//  `<` — and both are load-bearing in a way that is invisible from the call
//  site.
//
//  Too generous and every accepted fix re-matches a window that keeps growing,
//  on a phone in a pocket, for the length of the walk. Too tight and the
//  window collapses to a single point, which `scheduleLiveMatching` refuses to
//  match at all, so the matched trail name silently stops updating and nothing
//  reports why.
//
//  The function is `nonisolated static` and takes its points as an argument,
//  so these drive it directly rather than through a recording: what is being
//  pinned is arithmetic, and hand-built timestamps say what a delivered fix
//  never could — that a point exactly on the boundary is on the inside of it.
//

import Foundation
@testable import OpenHikes
import Testing

@Suite("Live match window")
struct LiveMatchWindowTests {
    /// Fixed rather than `Date()`, so the boundary cases below are the same
    /// arithmetic on every run.
    static let start = Date(timeIntervalSince1970: 1_700_000_000)

    static func points(_ count: Int, secondsApart: TimeInterval) -> [RecordingPoint] {
        (0..<count).map { index in
            RecordingPoint(
                latitude: 47.63 + Double(index) * 0.0001,
                longitude: 12.86,
                timestamp: start.addingTimeInterval(Double(index) * secondsApart),
                horizontalAccuracy: 8
            )
        }
    }

    /// Matching needs a leg, and a leg needs two points. Anything shorter is
    /// retained whole rather than trimmed to nothing.
    @Test(
        "a recording too short to have a window keeps all of it",
        arguments: [0, 1, 2]
    )
    func shortRecordingsAreRetainedWhole(count: Int) {
        let points = Self.points(count, secondsApart: 30)

        #expect(HikeRecorder.liveWindowRetainedStart(in: points) == 0)
    }

    /// The point cap is what stops a six-hour walk from re-matching six hours
    /// of fixes every time one arrives.
    @Test("a burst of recent fixes is trimmed to the point cap")
    func recentFixesAreTrimmedToThePointCap() throws {
        let interval = 1.0
        let count = 40
        let points = Self.points(count, secondsApart: interval)

        let retained = HikeRecorder.liveWindowRetainedStart(in: points)

        #expect(retained == count - HikeRecorder.liveMatchingMaximumPoints)
        let latest = try #require(points.last).timestamp
        #expect(
            latest.timeIntervalSince(points[retained].timestamp)
                < HikeRecorder.liveMatchingDuration,
            "even the oldest point kept is inside the window, so only the cap can have trimmed"
        )
    }

    /// A walker who stops for lunch comes back to a window whose points are
    /// minutes apart. The duration bound then trims further than the point cap
    /// already did, which is the case where the two bounds interact rather
    /// than one of them simply winning.
    @Test("a sparse recording is trimmed past the point cap by the duration")
    func sparseFixesAreTrimmedByTheDuration() throws {
        let interval = 25.0
        let count = 40
        let points = Self.points(count, secondsApart: interval)

        let retained = HikeRecorder.liveWindowRetainedStart(in: points)

        #expect(
            retained > count - HikeRecorder.liveMatchingMaximumPoints,
            "the duration has to bite harder than the cap here, or this is the previous test again"
        )
        let latest = try #require(points.last).timestamp
        let firstInside = points[retained + 1].timestamp
        #expect(latest.timeIntervalSince(firstInside) <= HikeRecorder.liveMatchingDuration)
        #expect(
            latest.timeIntervalSince(points[retained].timestamp) > HikeRecorder.liveMatchingDuration,
            "the point before the window is the anchor for the leg that crosses into it"
        )
    }

    /// The bound is `<`, not `<=`, and the difference is a whole point of the
    /// window: a fix landing exactly `liveMatchingDuration` before the newest
    /// one is inside it.
    @Test("a fix exactly on the window edge is inside it")
    func aFixOnTheEdgeIsRetained() throws {
        let interval = 30.0
        let count = 10
        let points = Self.points(count, secondsApart: interval)

        let retained = HikeRecorder.liveWindowRetainedStart(in: points)

        let latest = try #require(points.last).timestamp
        #expect(
            latest.timeIntervalSince(points[retained + 1].timestamp)
                == HikeRecorder.liveMatchingDuration,
            "these are spaced to put a fix exactly on the edge; it must be the first one kept"
        )
        #expect(
            points.count - retained == 4,
            "one point outside the window as an anchor, three inside it"
        )
    }

    /// Every point is older than the window, so the duration bound would walk
    /// the start off the end of the recording if nothing stopped it. What
    /// stops it is the same thing `scheduleLiveMatching` needs: a window of
    /// fewer than two points is not matchable, so the walker's matched trail
    /// name would stop updating entirely.
    @Test("a window whose points are all stale still keeps a matchable leg")
    func aStaleRecordingKeepsALeg() {
        let interval = 1000.0
        let count = 5
        let points = Self.points(count, secondsApart: interval)

        let retained = HikeRecorder.liveWindowRetainedStart(in: points)

        #expect(points.count - retained == 2)
    }
}
