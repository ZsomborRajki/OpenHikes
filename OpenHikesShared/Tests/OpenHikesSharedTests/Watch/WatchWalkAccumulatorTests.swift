//
//  WatchWalkAccumulatorTests.swift
//  OpenHikesSharedTests
//

import Foundation
@testable import OpenHikesShared
import Testing

@Suite("Watch walk accumulator")
struct WatchWalkAccumulatorTests {
    @Test("A fix the receiver is not sure about is not a position")
    func inaccurateFixIsRefused() {
        var walk = WatchWalkAccumulator()
        // Hoisted rather than written inside `#expect`, here and below: the
        // macro passes the receiver into a non-escaping closure, and a
        // `mutating` member cannot be called on it.
        let kept = walk.accept(
            latitude: Fixture.latitude,
            longitude: Fixture.longitude,
            timestamp: Fixture.start,
            horizontalAccuracy: WatchFixPolicy.maximumHorizontalAccuracy + 1
        )
        #expect(!kept)
        #expect(walk.fixes.isEmpty)
    }

    @Test("Standing still accumulates no distance, and is still timestamped")
    func standingStillIsNotAWalk() {
        var walk = WatchWalkAccumulator()
        walk.accept(
            latitude: Fixture.latitude,
            longitude: Fixture.longitude,
            timestamp: Fixture.start,
            horizontalAccuracy: 5
        )
        // A metre of receiver wander, a second later: below the gate, so it is
        // dropped entirely.
        let wander = walk.accept(
            latitude: Fixture.latitude + 0.00001,
            longitude: Fixture.longitude,
            timestamp: Fixture.start.addingTimeInterval(1),
            horizontalAccuracy: 5
        )
        #expect(!wander)
        // The same wander past the heartbeat: kept, so a rest stop leaves a
        // timestamp rather than a gap, and still worth almost no distance.
        let heartbeat = walk.accept(
            latitude: Fixture.latitude + 0.00001,
            longitude: Fixture.longitude,
            timestamp: Fixture.start.addingTimeInterval(WatchFixPolicy.maximumInterval),
            horizontalAccuracy: 5
        )
        #expect(heartbeat)
        #expect(walk.fixes.count == 2)
        #expect(walk.distanceMeters < 2)
    }

    @Test("A reordered pair is refused rather than subtracted")
    func reorderedFixIsRefused() {
        var walk = WatchWalkAccumulator()
        walk.accept(
            latitude: Fixture.latitude,
            longitude: Fixture.longitude,
            timestamp: Fixture.start.addingTimeInterval(30),
            horizontalAccuracy: 5
        )
        let reordered = walk.accept(
            latitude: Fixture.latitude + 0.001,
            longitude: Fixture.longitude,
            timestamp: Fixture.start,
            horizontalAccuracy: 5
        )
        #expect(!reordered)
    }

    @Test("Walking accumulates distance and the clock that goes with it")
    func walkingAccumulates() {
        let walk = Fixture.walkedNorth(steps: 4)
        #expect(walk.fixes.count == 5)
        // Four legs of about 11 m each.
        #expect(walk.distanceMeters > 40 && walk.distanceMeters < 50)
        #expect(walk.activeSeconds == 4 * Fixture.stepSeconds)
        let pace = walk.averageSpeedMetersPerSecond
        #expect(pace != nil)
    }

    @Test("The ground crossed during a pause is neither walked nor climbed")
    func aPauseBridgesNothing() {
        var walk = WatchWalkAccumulator()
        walk.accept(
            latitude: Fixture.latitude,
            longitude: Fixture.longitude,
            timestamp: Fixture.start,
            horizontalAccuracy: 5,
            elevationMeters: 600
        )
        walk.pause()
        // Resumed a kilometre away and 300 m higher, an hour later — a hiker
        // who took a lift to the ridge, which is exactly the stretch a pause
        // says was not meant to be observed.
        walk.accept(
            latitude: Fixture.latitude + 0.01,
            longitude: Fixture.longitude,
            timestamp: Fixture.start.addingTimeInterval(3600),
            horizontalAccuracy: 5,
            elevationMeters: 900
        )
        #expect(walk.distanceMeters == 0)
        #expect(walk.activeSeconds == 0)
        #expect(walk.elevationGainMeters == 0)
        #expect(walk.fixes.last?.resumesAfterPause == true)
    }

    @Test("The first fix of all is not a resume")
    func theFirstFixIsNotAResume() {
        var walk = WatchWalkAccumulator()
        walk.pause()
        walk.accept(
            latitude: Fixture.latitude,
            longitude: Fixture.longitude,
            timestamp: Fixture.start,
            horizontalAccuracy: 5
        )
        #expect(walk.fixes.first?.resumesAfterPause == false)
    }

    @Test("Altimeter noise on a flat walk is not a climb")
    func noiseIsNotClimb() {
        var walk = WatchWalkAccumulator()
        var height = 600.0
        for step in 0...20 {
            // ±0.4 m either side of flat, which is under the floor and must
            // add up to nothing however many readings there are.
            height += step.isMultiple(of: 2) ? 0.4 : -0.4
            walk.accept(
                latitude: Fixture.latitude + Double(step) * 0.0001,
                longitude: Fixture.longitude,
                timestamp: Fixture.start.addingTimeInterval(Double(step) * Fixture.stepSeconds),
                horizontalAccuracy: 5,
                elevationMeters: height
            )
        }
        #expect(walk.elevationGainMeters == 0)
        #expect(walk.elevationLossMeters == 0)
    }

    @Test("A real climb and the descent off it are both counted")
    func climbAndDescentAreBothCounted() {
        var walk = WatchWalkAccumulator()
        for (step, height) in [600.0, 650, 700, 660, 620].enumerated() {
            walk.accept(
                latitude: Fixture.latitude + Double(step) * 0.0001,
                longitude: Fixture.longitude,
                timestamp: Fixture.start.addingTimeInterval(Double(step) * Fixture.stepSeconds),
                horizontalAccuracy: 5,
                elevationMeters: height
            )
        }
        #expect(walk.elevationGainMeters == 100)
        #expect(walk.elevationLossMeters == 80)
    }

    @Test("A recording with one fix is a place, and does not become a hike")
    func onePointIsNotWorthSending() {
        var walk = WatchWalkAccumulator()
        walk.accept(
            latitude: Fixture.latitude,
            longitude: Fixture.longitude,
            timestamp: Fixture.start,
            horizontalAccuracy: 5
        )
        let sent = walk.recordedWalk(
            sessionID: UUID(),
            startedAt: Fixture.start,
            endedAt: Fixture.start
        )
        #expect(sent == nil)
    }

    @Test("A walk carries the totals the hiker was shown")
    func theWalkCarriesItsTotals() throws {
        let walk = Fixture.walkedNorth(steps: 4)
        let sent = try #require(
            walk.recordedWalk(
                sessionID: Fixture.sessionID,
                startedAt: Fixture.start,
                endedAt: Fixture.start.addingTimeInterval(4 * Fixture.stepSeconds),
                title: "Rinnkendlsteig"
            )
        )
        #expect(sent.sessionID == Fixture.sessionID)
        #expect(sent.distanceMeters == walk.distanceMeters)
        #expect(sent.activeSeconds == walk.activeSeconds)
        #expect(sent.fixes.count == walk.fixes.count)
        #expect(sent.title == "Rinnkendlsteig")
    }

    private enum Fixture {
        static let latitude = 47.55
        static let longitude = 12.90
        static let start = Date(timeIntervalSince1970: 1_700_000_000)
        static let stepSeconds: TimeInterval = 8
        static let sessionID = UUID(uuidString: "33333333-3333-3333-3333-333333333333") ?? UUID()

        /// Steps of about 11 m due north, which clears the displacement gate
        /// without being a speed a walk could not support.
        static func walkedNorth(steps: Int) -> WatchWalkAccumulator {
            var walk = WatchWalkAccumulator()
            for step in 0...steps {
                walk.accept(
                    latitude: latitude + Double(step) * 0.0001,
                    longitude: longitude,
                    timestamp: start.addingTimeInterval(Double(step) * stepSeconds),
                    horizontalAccuracy: 5
                )
            }
            return walk
        }
    }
}
