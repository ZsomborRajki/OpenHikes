//
//  RecordingSpeedCorroborationTests.swift
//  OpenHikesTests
//
//  When the speed a fix reports bears out the speed its displacement implies
//  (``RecordingFixPolicy/reportedSpeed(_:corroborates:)``), and that the gates
//  around ``RecordingFixPolicy`` still decide when that is asked.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import Testing

nonisolated private let corroborationLatitude = 47.63
nonisolated private let corroborationLongitude = 12.86
nonisolated private let corroborationAltitude: CLLocationDistance = 600
nonisolated private let metersPerDegreeLatitude = 111_000.0

/// A fix the given distance north of the anchor, with no speed of its own
/// unless one is passed.
nonisolated private func corroborationLocation(
    northMeters: Double,
    at timestamp: Date,
    speed: CLLocationSpeed = -1
) -> CLLocation {
    CLLocation(
        coordinate: CLLocationCoordinate2D(
            latitude: corroborationLatitude + northMeters / metersPerDegreeLatitude,
            longitude: corroborationLongitude
        ),
        altitude: corroborationAltitude,
        horizontalAccuracy: 8,
        verticalAccuracy: 5,
        course: -1,
        speed: speed,
        timestamp: timestamp
    )
}

@Suite("Recording fix policy, speed corroboration")
struct RecordingSpeedCorroborationTests {
    private let start = Date(timeIntervalSince1970: 1_750_000_000)

    /// An implied 20 m/s is allowed 35 % either way, which is 7 m/s exactly in
    /// binary as well; an implied 4 m/s is allowed the 2 m/s floor, which
    /// outranks its 1.4. Every figure here sits on the edge or one
    /// representable step past it, and each subtraction is exact, so nothing
    /// hides in rounding.
    @Test("a reported speed on the edge of the tolerance corroborates, and one step past it does not")
    func toleranceEdgeIsInclusive() {
        let fast: CLLocationSpeed = 20
        let fastAbove: CLLocationSpeed = 27
        let fastBelow: CLLocationSpeed = 13
        #expect(RecordingFixPolicy.reportedSpeed(fastAbove, corroborates: fast))
        #expect(RecordingFixPolicy.reportedSpeed(fastBelow, corroborates: fast))
        #expect(!RecordingFixPolicy.reportedSpeed(fastAbove.nextUp, corroborates: fast))
        #expect(!RecordingFixPolicy.reportedSpeed(fastBelow.nextDown, corroborates: fast))

        let slow: CLLocationSpeed = 4
        let slowAbove: CLLocationSpeed = 6
        #expect(RecordingFixPolicy.reportedSpeed(slowAbove, corroborates: slow))
        #expect(RecordingFixPolicy.reportedSpeed(2, corroborates: slow))
        #expect(!RecordingFixPolicy.reportedSpeed(slowAbove.nextUp, corroborates: slow))
    }

    /// Core Location reports a negative speed when it has none. Against an
    /// implied 1 m/s, −1 sits on the edge of the 2 m/s floor as a number, and
    /// still bears out nothing.
    @Test("an unavailable reported speed corroborates nothing")
    func unavailableSpeedCorroboratesNothing() {
        #expect(!RecordingFixPolicy.reportedSpeed(-1, corroborates: 1))
        #expect(!RecordingFixPolicy.reportedSpeed(-1, corroborates: 20))
        #expect(!RecordingFixPolicy.reportedSpeed(.nan, corroborates: 20))
        // Standing still is a speed, and an available one.
        #expect(RecordingFixPolicy.reportedSpeed(0, corroborates: 1))
    }

    @Test("a reported speed outside the tolerance does not corroborate")
    func speedOutsideToleranceDoesNotCorroborate() {
        // A walking pace against a teleport, and twice the teleport.
        #expect(!RecordingFixPolicy.reportedSpeed(1.4, corroborates: 20))
        #expect(!RecordingFixPolicy.reportedSpeed(40, corroborates: 20))
    }

    /// The comparison takes only a finite tolerance, and an infinite implied
    /// speed would make an infinite one. The `interval > 0` guard keeps such a
    /// speed from reaching it through ``RecordingFixPolicy/accepts(_:after:motionState:now:)``;
    /// this holds the predicate to refusing one rather than comparing it.
    @Test("an implied speed that is not finite is refused, not compared")
    func nonFiniteImpliedSpeedIsRefused() {
        #expect(!RecordingFixPolicy.reportedSpeed(20, corroborates: .infinity))
        #expect(!RecordingFixPolicy.reportedSpeed(.infinity, corroborates: .infinity))
        #expect(!RecordingFixPolicy.reportedSpeed(20, corroborates: .nan))
    }

    /// The comparison is asked only of a fix past the walking ceiling, on
    /// foot or of unknown motion, while the anchor is inside the heartbeat.
    /// A fix with no speed of its own fails the comparison whenever it is
    /// asked, so each gate shows here by letting that fix through.
    @Test("the speed, motion and interval gates still decide when the comparison is asked")
    func gatesDecideWhenTheComparisonIsAsked() {
        let anchor = RecordingPoint(
            location: corroborationLocation(northMeters: 0, at: start)
        )

        // 100 m in 5 s is 20 m/s: refused on foot, kept in a vehicle.
        let fast = corroborationLocation(northMeters: 100, at: start.addingTimeInterval(5))
        #expect(!RecordingFixPolicy.accepts(fast, after: anchor, now: fast.timestamp))
        #expect(RecordingFixPolicy.accepts(
            fast,
            after: anchor,
            motionState: .nonPedestrian,
            now: fast.timestamp
        ))

        // Still 20 m/s, but at the heartbeat.
        let atHeartbeat = corroborationLocation(
            northMeters: 200,
            at: start.addingTimeInterval(RecordingFixPolicy.maximumInterval)
        )
        #expect(RecordingFixPolicy.accepts(atHeartbeat, after: anchor, now: atHeartbeat.timestamp))

        // 30 m in 5 s is 6 m/s, under the ceiling, so nothing is compared.
        let brisk = corroborationLocation(northMeters: 30, at: start.addingTimeInterval(5))
        #expect(RecordingFixPolicy.accepts(brisk, after: anchor, now: brisk.timestamp))
    }
}
