//
//  LoopWalkStartTests.swift
//  OpenHikesTests
//
//  The automatic start where a route's two ends are one place, end to end:
//  fixes through the matcher the detail follows with (`FollowAnchor`), and
//  every match into `TrailWalkSession` as `HikeDetailView`'s follow loop
//  hands it over.
//
//  `PendingWalkStartTests` assume a matcher that reports where the hiker is.
//  At a loop's trailhead it reports one end and then the other, and only the
//  two together show what that does to a walk's start.
//

import CoreLocation
import Foundation
import OpenHikesData
import SwiftData
import Testing

@testable import OpenHikes

@Suite("Starting a walk where a route's ends meet")
struct LoopWalkStartTests {
    private static let metersPerDegreeLatitude = 111_320.0
    private static let metersPerDegreeLongitude = 111_320.0 * cos(47 * Double.pi / 180)
    /// A fix every ten metres at a walking pace.
    private static let secondsPerFix: TimeInterval = 8

    private let container: ModelContainer
    private let context: ModelContext
    private let clock = TestClock()

    init() throws {
        container = try Fixture.modelContainer()
        context = ModelContext(container)
    }

    private static func point(north: Double, east: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(
            latitude: 47 + north / metersPerDegreeLatitude,
            longitude: 12 + east / metersPerDegreeLongitude
        )
    }

    /// A line through `corners`, as metres north and east of the trailhead,
    /// with a point every ten metres along each leg.
    private static func line(through corners: [(north: Double, east: Double)]) -> [RouteCoordinate] {
        guard var last = corners.first else { return [] }
        var line = [point(north: last.north, east: last.east)]
        for corner in corners.dropFirst() {
            let north = corner.north - last.north
            let east = corner.east - last.east
            let steps = max(1, Int(((north * north + east * east).squareRoot() / 10).rounded()))
            for step in 1...steps {
                let fraction = Double(step) / Double(steps)
                line.append(point(north: last.north + north * fraction, east: last.east + east * fraction))
            }
            last = corner
        }
        return line.map { RouteCoordinate($0) }
    }

    /// A two-kilometre square: north from the trailhead, east, south, and
    /// back west into it. The way in and the way out meet at a right angle,
    /// as a car park's two paths do.
    private static var loop: [RouteCoordinate] {
        line(through: [(0, 0), (500, 0), (500, 500), (0, 500), (0, 0)])
    }

    /// A kilometre north and back along the same path, the way home three
    /// metres to the east.
    private static var outAndBack: [RouteCoordinate] {
        line(through: [(0, 0), (1000, 0), (1000, 3), (0, 3)])
    }

    /// A four-kilometre figure-eight whose trailhead is its crossing: a loop
    /// to the north-west, back through the trailhead halfway, and a loop to
    /// the south-east.
    private static var figureEight: [RouteCoordinate] {
        line(through: [
            (0, 0), (500, 0), (500, -500), (0, -500), (0, 0),
            (-500, 0), (-500, 500), (0, 500), (0, 0),
        ])
    }

    /// Two loops from one car park recorded as one hike, the three-kilometre
    /// one first: back through the trailhead three quarters of the way along.
    private static var twoLoops: [RouteCoordinate] {
        line(through: [
            (0, 0), (750, 0), (750, -750), (0, -750), (0, 0),
            (-250, 0), (-250, 250), (0, 250), (0, 0),
        ])
    }

    /// One fix, as the receiver took it now — `nil` course for a hiker
    /// standing still.
    private func fix(north: Double, east: Double, course: CLLocationDirection?) -> RouteFix {
        RouteFix(
            coordinate: Self.point(north: north, east: east),
            horizontalAccuracy: 5,
            course: course,
            timestamp: clock.now
        )
    }

    /// Opens `route` standing at `start`, then walks `steps` ten-metre steps
    /// from there, `walk` saying where each one lands and which way it faces.
    /// - Returns: the metres walked when the walk started, or `nil` if it
    ///   never did.
    private func walkedMetersToStart(
        on route: [RouteCoordinate],
        standingAt start: (north: Double, east: Double),
        steps: Int,
        walk: (Double) -> (north: Double, east: Double, course: CLLocationDirection)
    ) -> Double? {
        let hike = Fixture.hike(in: context, title: "Trailhead", route: route)
        let profile = RouteProfile(route: route)
        let session = TrailWalkSession(context: context, clock: clock.read)
        var anchor: FollowAnchor?
        // What `HikeDetailView.updateLiveFollow` does with a fix: match it,
        // and hand the walk session the match or the miss.
        func follow(_ fix: RouteFix) {
            let match = FollowAnchor.advance(&anchor, on: profile, to: fix, scope: .wholeRoute)
            guard let match, match.offRouteMeters <= RouteProfile.followMatchThresholdMeters else {
                session.recordOffRoute(hikeID: hike.id)
                return
            }
            session.recordForegroundMatch(
                hike: hike,
                profile: profile,
                distance: match.distanceAlongRoute,
                accuracy: fix.horizontalAccuracy,
                at: fix.timestamp
            )
        }
        follow(fix(north: start.north, east: start.east, course: nil))
        for step in 1...steps {
            clock.advance(by: Self.secondsPerFix)
            let walked = Double(step) * 10
            let place = walk(walked)
            follow(fix(north: place.north, east: place.east, course: place.course))
            if session.walkedHikeID == hike.id { return walked }
        }
        return nil
    }

    /// The case the start was written for, as a baseline for the one below.
    @Test("a loop walked the way it is stored starts a walk")
    func theStoredWayStarts() throws {
        let walked = try #require(walkedMetersToStart(on: Self.loop, standingAt: (0, 0), steps: 40) { meters in
            (north: meters, east: 0, course: 0)
        })
        #expect(walked <= 2 * PendingWalkStart.confirmingMeters)
    }

    /// The trailhead is both ends of the loop. Standing there, the hiker is
    /// matched at its start; heading off the other way round, the matcher
    /// keeps them there until they are out of the start's reach, then finds
    /// them near the end — most of the route away from where the proposal
    /// found them, and every step after that one nearer it.
    @Test("a loop walked against the way it is stored starts a walk")
    func theOtherWayRoundStarts() throws {
        let walked = try #require(walkedMetersToStart(on: Self.loop, standingAt: (0, 0), steps: 40) { meters in
            (north: 0, east: meters, course: 90)
        })
        #expect(walked <= 3 * PendingWalkStart.confirmingMeters)
    }

    /// The other route whose ends meet, where the other end is not the way
    /// round. A hiker standing on the way home is placed on the way out, and
    /// their first step home moves them to the leg beside it: nearly the
    /// whole route along, a few metres from where they stood.
    @Test("an out-and-back opened on the way home starts a walk")
    func theWayHomeStarts() throws {
        let walked = try #require(walkedMetersToStart(on: Self.outAndBack, standingAt: (300, 3), steps: 25) { meters in
            (north: 300 - meters, east: 3, course: 180)
        })
        #expect(walked <= 2 * PendingWalkStart.confirmingMeters)
    }

    /// A route can come back through its trailhead before its end. Setting
    /// off the stored way along that later pass, the hiker is matched just
    /// past it, halfway along the figure-eight, and walks away from it.
    @Test("a figure-eight set off from its crossing onto the second loop starts a walk")
    func theSecondLoopStarts() throws {
        let walked = try #require(walkedMetersToStart(on: Self.figureEight, standingAt: (0, 0), steps: 40) { meters in
            (north: -meters, east: 0, course: 180)
        })
        #expect(walked <= 2 * PendingWalkStart.confirmingMeters)
    }

    @Test("the second of two loops from one car park starts a walk")
    func theShortLoopStarts() throws {
        let walked = try #require(walkedMetersToStart(on: Self.twoLoops, standingAt: (0, 0), steps: 25) { meters in
            (north: -meters, east: 0, course: 180)
        })
        #expect(walked <= 2 * PendingWalkStart.confirmingMeters)
    }
}
