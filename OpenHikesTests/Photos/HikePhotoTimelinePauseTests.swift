//
//  HikePhotoTimelinePauseTests.swift
//  OpenHikesTests
//
//  What a timeline says about a photograph taken while the recording was
//  paused.
//
//  A pause is not a gap the receiver failed to fill: the hiker switched the
//  recording off, and the leg between the fix before it and the fix that
//  resumed it is not part of the walk. A paused leg can be short in time and
//  long in distance — a cable car, a lift to the next trailhead — so the
//  grace that lets a *gap* be interpolated across is exactly what must not
//  apply here. Each test below is one way the two used to be confused.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import Testing

@Suite("Hike photo timeline across a pause")
struct HikePhotoTimelinePauseTests {
    private static let latitude: Double = 47.0
    private static let longitude: Double = 12.0
    /// About 2 km of latitude, which is the leg #870 reproduced with: far
    /// enough that a point halfway along it is plainly somewhere else.
    private static let pausedLegDegrees = 0.018
    /// ~111 m, a minute of ordinary walking.
    private static let stepDegrees = 0.001
    private static let stepSeconds: TimeInterval = 60
    private static let epoch = Date(timeIntervalSince1970: 1_750_000_000)
    private static let toleranceMeters = 0.5

    private static let beforePause = CLLocationCoordinate2D(
        latitude: latitude,
        longitude: longitude
    )
    private static let resumed = CLLocationCoordinate2D(
        latitude: latitude + pausedLegDegrees,
        longitude: longitude
    )

    /// A fix, a pause lasting `pause` seconds, the fix that resumed it, and
    /// one ordinary minute of walking after that.
    private static func route(pause: TimeInterval) -> [RouteCoordinate] {
        [
            RouteCoordinate(
                latitude: beforePause.latitude,
                longitude: beforePause.longitude,
                timestamp: epoch
            ),
            RouteCoordinate(
                latitude: resumed.latitude,
                longitude: resumed.longitude,
                timestamp: epoch.addingTimeInterval(pause),
                boundary: .paused
            ),
            RouteCoordinate(
                latitude: resumed.latitude + stepDegrees,
                longitude: resumed.longitude,
                timestamp: epoch.addingTimeInterval(pause + stepSeconds)
            ),
        ]
    }

    private static func meters(
        from position: HikePhotoTimeline.Position,
        to coordinate: CLLocationCoordinate2D
    ) -> Double {
        RouteGeometry.distanceMeters(from: position.coordinate, to: coordinate)
    }

    @Test("fixes remember their original recording segment")
    func segmentsAreCarriedIntoFixes() throws {
        let timeline = try #require(HikePhotoTimeline(route: Self.route(pause: 360)))

        #expect(timeline.fixes.map(\.segment) == [0, 1, 1])
    }

    /// The route an import or a matcher splices can carry the boundary on a
    /// point with no clock. The pause still happened between the fixes either
    /// side of it, so the next timestamped fix starts a different segment.
    @Test("a pause on an untimestamped point separates the next fix")
    func pauseOnAnUnstampedPointIsKept() throws {
        var route = Self.route(pause: 360)
        route[1].boundary = nil
        route.insert(
            RouteCoordinate(
                latitude: Self.resumed.latitude,
                longitude: Self.resumed.longitude,
                boundary: .paused
            ),
            at: 1
        )

        let timeline = try #require(HikePhotoTimeline(route: route))

        #expect(timeline.fixes.map(\.segment) == [0, 1, 1])
    }

    @Test("a discarded duplicate cannot hide a pause", arguments: [false, true])
    func pauseOnADiscardedDuplicateIsKept(unstampedResume: Bool) throws {
        var route = Self.route(pause: 360)
        route.insert(
            RouteCoordinate(
                latitude: Self.beforePause.latitude,
                longitude: Self.beforePause.longitude,
                timestamp: Self.epoch.addingTimeInterval(360)
            ),
            at: 1
        )
        if unstampedResume {
            route[2].timestamp = nil
            route.insert(
                RouteCoordinate(
                    latitude: Self.resumed.latitude,
                    longitude: Self.resumed.longitude,
                    timestamp: Self.epoch.addingTimeInterval(360)
                ),
                at: 3
            )
        }

        let timeline = try #require(HikePhotoTimeline(route: route))
        let position = try #require(
            timeline.position(at: Self.epoch.addingTimeInterval(390))
        )

        #expect(timeline.fixes.count == 3)
        #expect(Self.meters(from: position, to: Self.beforePause) < Self.toleranceMeters)
        #expect(position.secondsFromFix == 30)
    }

    @Test("sorting keeps a pause between the original recording segments")
    func sortedFixesKeepTheirSegments() throws {
        var route = Self.route(pause: 360)
        route[2].timestamp = Self.epoch.addingTimeInterval(300)
        let timeline = try #require(HikePhotoTimeline(route: route))

        let duringPause = try #require(
            timeline.position(at: Self.epoch.addingTimeInterval(150))
        )
        let withinSegment = try #require(
            timeline.position(at: Self.epoch.addingTimeInterval(330))
        )

        #expect(Self.meters(from: duringPause, to: Self.beforePause) < Self.toleranceMeters)
        #expect(duringPause.secondsFromFix == 150)
        let expected = CLLocationCoordinate2D(
            latitude: Self.resumed.latitude + Self.stepDegrees / 2,
            longitude: Self.resumed.longitude
        )
        #expect(Self.meters(from: withinSegment, to: expected) < Self.toleranceMeters)
        #expect(withinSegment.secondsFromFix == 30)
    }

    @Test("interleaved timestamps cannot join different recording segments")
    func interleavedSegmentsAreNotInterpolated() throws {
        var route = Self.route(pause: 300)
        route.insert(
            RouteCoordinate(
                latitude: Self.beforePause.latitude,
                longitude: Self.beforePause.longitude,
                timestamp: Self.epoch.addingTimeInterval(330)
            ),
            at: 1
        )
        let timeline = try #require(HikePhotoTimeline(route: route))

        let position = try #require(
            timeline.position(at: Self.epoch.addingTimeInterval(315))
        )

        #expect(Self.meters(from: position, to: Self.resumed) < Self.toleranceMeters)
        #expect(position.secondsFromFix == 15)
    }

    /// The reproduction in #870: six minutes paused, a photo three minutes
    /// in. Interpolation put it at the midpoint of the 2 km leg; the answer
    /// is the fix the pause started from, three minutes away.
    @Test("a photo during a short pause is placed at an end, not along the leg")
    func shortPauseIsNotInterpolated() throws {
        let timeline = try #require(HikePhotoTimeline(route: Self.route(pause: 360)))

        let position = try #require(
            timeline.position(at: Self.epoch.addingTimeInterval(180))
        )

        #expect(
            Self.meters(from: position, to: Self.beforePause) < Self.toleranceMeters
        )
        #expect(position.secondsFromFix == 180)
    }

    @Test("a photo late in a short pause is placed where the walk resumed")
    func lateInAShortPauseIsPlacedAtTheResume() throws {
        let timeline = try #require(HikePhotoTimeline(route: Self.route(pause: 360)))

        let position = try #require(
            timeline.position(at: Self.epoch.addingTimeInterval(300))
        )

        #expect(Self.meters(from: position, to: Self.resumed) < Self.toleranceMeters)
        #expect(position.secondsFromFix == 60)
    }

    @Test("the middle of a long pause is not placed")
    func middleOfALongPauseIsRefused() throws {
        let pause = HikePhotoTimeline.graceInterval * 8
        let timeline = try #require(HikePhotoTimeline(route: Self.route(pause: pause)))

        #expect(timeline.position(at: Self.epoch.addingTimeInterval(pause / 2)) == nil)
    }

    @Test("the edges of a long pause are placed at their own fix")
    func edgesOfALongPauseArePlaced() throws {
        let pause = HikePhotoTimeline.graceInterval * 8
        let timeline = try #require(HikePhotoTimeline(route: Self.route(pause: pause)))
        let grace = HikePhotoTimeline.graceInterval

        let afterPausing = try #require(
            timeline.position(at: Self.epoch.addingTimeInterval(grace - 1))
        )
        let beforeResuming = try #require(
            timeline.position(at: Self.epoch.addingTimeInterval(pause - grace + 1))
        )

        #expect(
            Self.meters(from: afterPausing, to: Self.beforePause) < Self.toleranceMeters
        )
        #expect(afterPausing.secondsFromFix == grace - 1)
        #expect(
            Self.meters(from: beforeResuming, to: Self.resumed) < Self.toleranceMeters
        )
        #expect(beforeResuming.secondsFromFix == grace - 1)
    }

    @Test("a photo taken on the resumed fix is placed at it exactly")
    func photoOnTheResumedFixIsExact() throws {
        let timeline = try #require(HikePhotoTimeline(route: Self.route(pause: 360)))

        let position = try #require(
            timeline.position(at: Self.epoch.addingTimeInterval(360))
        )

        #expect(position.secondsFromFix == 0)
        #expect(Self.meters(from: position, to: Self.resumed) < Self.toleranceMeters)
    }

    /// The refusal belongs to the paused leg alone: the segment the resume
    /// opened is ordinary walking and is still interpolated along.
    @Test("a photo inside the segment after a pause is still interpolated")
    func segmentAfterAPauseIsInterpolated() throws {
        let timeline = try #require(HikePhotoTimeline(route: Self.route(pause: 360)))

        let position = try #require(
            timeline.position(
                at: Self.epoch.addingTimeInterval(360 + Self.stepSeconds / 2)
            )
        )

        let expected = CLLocationCoordinate2D(
            latitude: Self.resumed.latitude + Self.stepDegrees / 2,
            longitude: Self.resumed.longitude
        )
        #expect(Self.meters(from: position, to: expected) < Self.toleranceMeters)
        #expect(position.secondsFromFix == Self.stepSeconds / 2)
    }
}
