//
//  HikeWalkPhotoTimelineTests.swift
//  OpenHikesTests
//
//  What a walk can say about where its hiker was, and where it stops.
//
//  Values only: this type is a window and a covered stretch, and neither needs
//  a route, a store or a library to be exercised. What the tests below pin is
//  the shape of the guess — even progress through the union, in route order,
//  with the same five-minute grace a recorded route is given — and, just as
//  much, the cases the type refuses outright.
//

import Foundation
@testable import OpenHikes
import Testing

@Suite("Hike walk photo timeline")
struct HikeWalkPhotoTimelineTests {
    private static let start = Date(timeIntervalSince1970: 1_750_000_000)
    private static let minute: TimeInterval = 60

    private static func timeline(
        minutes: Double = 60,
        intervals: [Double] = [0, 1000]
    ) -> HikeWalkPhotoTimeline? {
        HikeWalkPhotoTimeline(
            startedAt: start,
            endedAt: start.addingTimeInterval(minutes * minute),
            coverage: TrailWalkCoverage(
                intervals: intervals,
                furthestDistanceMeters: intervals.max() ?? 0
            )
        )
    }

    /// A walk that covered nothing is a walk that cannot place anything, and
    /// the window it would otherwise open is a fetch across somebody's whole
    /// afternoon for no possible answer.
    @Test("a walk that covered nothing places nothing")
    func emptyCoverageIsRefused() {
        #expect(Self.timeline(intervals: []) == nil)
        #expect(Self.timeline(intervals: [400, 400]) == nil)
    }

    @Test("a walk whose clock runs backwards is refused")
    func backwardsClockIsRefused() {
        let timeline = HikeWalkPhotoTimeline(
            startedAt: Self.start,
            endedAt: Self.start.addingTimeInterval(-Self.minute),
            coverage: TrailWalkCoverage(intervals: [0, 1000], furthestDistanceMeters: 1000)
        )
        #expect(timeline == nil)
    }

    /// The same grace a recorded route gets, and for the same reason: the
    /// trailhead photograph taken while the walk was still being started is a
    /// photograph of the walk.
    @Test("the window carries the recorded route's grace at both ends")
    func windowCarriesTheGrace() throws {
        let timeline = try #require(Self.timeline())
        let grace = HikePhotoTimeline.graceInterval

        #expect(timeline.searchWindow.lowerBound == Self.start.addingTimeInterval(-grace))
        #expect(
            timeline.searchWindow.upperBound
                == Self.start.addingTimeInterval(60 * Self.minute + grace)
        )
    }

    /// The central guess: a walk that covered a kilometre in an hour is half
    /// way along it after half an hour. Crude, and the only thing the stored
    /// row supports — see the file header of ``HikeWalkPhotoTimeline``.
    @Test("progress is spread evenly over the distance actually covered")
    func progressIsEvenAcrossTheCoveredDistance() throws {
        let timeline = try #require(Self.timeline())

        #expect(timeline.distanceAlongRoute(at: Self.start) == 0)
        #expect(timeline.distanceAlongRoute(at: Self.start.addingTimeInterval(30 * Self.minute)) == 500)
        #expect(timeline.distanceAlongRoute(at: Self.start.addingTimeInterval(60 * Self.minute)) == 1000)
    }

    /// A stretch the walk never covered is a stretch it cannot have been
    /// photographed on, so progress steps over it rather than through it: at
    /// three quarters of the clock the hiker has done 150 of their 200 covered
    /// metres, which lands 50 m into the second interval and not at 750.
    @Test("a gap in the coverage is stepped over, not walked through")
    func progressSkipsWhatWasNeverCovered() throws {
        let timeline = try #require(Self.timeline(intervals: [0, 100, 300, 400]))

        #expect(timeline.coveredMeters == 200)
        #expect(timeline.distanceAlongRoute(at: Self.start.addingTimeInterval(45 * Self.minute)) == 350)
    }

    @Test("a photo taken inside the grace is placed at the end nearest it")
    func graceIsPlacedAtTheNearestEnd() throws {
        let timeline = try #require(Self.timeline(intervals: [200, 900]))
        let beforeStart = Self.start.addingTimeInterval(-2 * Self.minute)
        let afterEnd = Self.start.addingTimeInterval(62 * Self.minute)

        #expect(timeline.distanceAlongRoute(at: beforeStart) == 200)
        #expect(timeline.distanceAlongRoute(at: afterEnd) == 900)
    }

    @Test("a moment outside the window has no place on the walk")
    func outsideTheWindowIsRefused() throws {
        let timeline = try #require(Self.timeline())
        let longBefore = Self.start.addingTimeInterval(-HikePhotoTimeline.graceInterval - 1)
        let longAfter = Self.start
            .addingTimeInterval(60 * Self.minute + HikePhotoTimeline.graceInterval + 1)

        #expect(timeline.distanceAlongRoute(at: longBefore) == nil)
        #expect(timeline.distanceAlongRoute(at: longAfter) == nil)
    }

    /// The test a bare route cannot make: whether a place is part of what
    /// *this* walk covered. The slack either side is the walk's own match
    /// cadence, not a tolerance on the answer.
    @Test("coverage decides what belongs, within the slack")
    func coverageDecidesWithSlack() throws {
        let timeline = try #require(Self.timeline(intervals: [500, 900]))
        let slack = HikeWalkPhotoTimeline.coverageSlackMeters

        #expect(timeline.covers(700))
        #expect(timeline.covers(500 - slack))
        #expect(timeline.covers(900 + slack))
        #expect(!timeline.covers(500 - slack - 1))
        #expect(!timeline.covers(900 + slack + 1))
    }
}
