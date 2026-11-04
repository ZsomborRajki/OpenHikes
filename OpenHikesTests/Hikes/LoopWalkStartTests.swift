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

    /// A two-kilometre square, a point every ten metres: north from the
    /// trailhead, east, south, and back west into it. The way in and the way
    /// out meet at a right angle, as a car park's two paths do.
    private static var loop: [RouteCoordinate] {
        var line: [CLLocationCoordinate2D] = []
        for step in 0..<50 { line.append(point(north: Double(step) * 10, east: 0)) }
        for step in 0..<50 { line.append(point(north: 500, east: Double(step) * 10)) }
        for step in 0..<50 { line.append(point(north: 500 - Double(step) * 10, east: 500)) }
        for step in 0...50 { line.append(point(north: 0, east: 500 - Double(step) * 10)) }
        return line.map { RouteCoordinate($0) }
    }

    /// A kilometre north and back along the same path, the way home three
    /// metres to the east.
    private static var outAndBack: [RouteCoordinate] {
        var line: [CLLocationCoordinate2D] = []
        for step in 0...100 { line.append(point(north: Double(step) * 10, east: 0)) }
        for step in (0...100).reversed() { line.append(point(north: Double(step) * 10, east: 3)) }
        return line.map { RouteCoordinate($0) }
    }

    /// One fix, as the receiver took it now — `nil` course for a hiker
    /// standing still.
    private func fix(north: Double, east: Double, course: CLLocationDirection?) -> RouteFix {
        RouteFix(coordinate: Self.point(north: north, east: east), course: course, timestamp: clock.now)
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
}
