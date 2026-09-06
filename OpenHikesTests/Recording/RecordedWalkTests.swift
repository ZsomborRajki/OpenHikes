//
//  RecordedWalkTests.swift
//  OpenHikesTests
//

import CoreLocation
import Foundation
@testable import OpenHikes
import Testing

/// The row a saved recording leaves in its own History: what it is measured
/// against, and what it does with the walker's pauses.
@Suite("Recorded walk")
struct RecordedWalkTests {
    private let start = Date(timeIntervalSince1970: 1_750_000_000)

    // MARK: Fixtures

    private func metadata(
        startedAt: Date,
        endedAt: Date?,
        pauses: [RecordingPauseInterval] = [],
        sessionID: UUID = UUID()
    ) -> TrackJournalMetadata {
        TrackJournalMetadata(
            sessionID: sessionID,
            startedAt: startedAt,
            endedAt: endedAt,
            lastUpdatedAt: endedAt ?? startedAt,
            pausedIntervals: pauses,
            title: nil
        )
    }

    private func prepared(
        startedAt: Date,
        routeLengthMeters: Double,
        distanceMeters: Double = 0
    ) -> PreparedRecording {
        PreparedRecording(
            route: [],
            rawRoute: [],
            distanceMeters: distanceMeters,
            routeLengthMeters: routeLengthMeters,
            startedAt: startedAt,
            matchedTrailName: nil,
            matchResult: nil
        )
    }

    /// A straight climb with a ninety-second stop in the middle, where the
    /// walker stands still and lets GPS wander: the one shape where the
    /// distance the hike reports and the length of the line it saved are
    /// different numbers.
    private func wanderingFixture() -> [RecordingPoint] {
        let metre = 1 / 111_320.0
        var points: [RecordingPoint] = []
        var latitude = 47.63
        var offset: TimeInterval = 0
        for _ in 0..<6 {
            points.append(point(latitude, 12.8601, at: offset))
            latitude += 15 * metre
            offset += 15
        }
        let standing = latitude
        for step in 0..<9 {
            points.append(point(
                standing + Double((step % 2) * 2 - 1) * 5 * metre,
                step.isMultiple(of: 2) ? 12.860075 : 12.860125,
                at: offset
            ))
            offset += 10
        }
        latitude = standing
        for _ in 0..<6 {
            latitude += 15 * metre
            offset += 15
            points.append(point(latitude, 12.8601, at: offset))
        }
        return points
    }

    private func point(
        _ latitude: Double,
        _ longitude: Double,
        at offset: TimeInterval
    ) -> RecordingPoint {
        RecordingPoint(
            latitude: latitude,
            longitude: longitude,
            timestamp: start.addingTimeInterval(offset),
            horizontalAccuracy: 8,
            elevation: 600 + offset / 60
        )
    }

    // MARK: Active time

    @Test("a recording's active time is its clock minus the pauses inside it")
    func activeTimeSubtractsPauses() {
        let endedAt = start.addingTimeInterval(3600)
        let seconds = RecordedWalk.activeSeconds(
            from: start,
            to: endedAt,
            pauses: [
                RecordingPauseInterval(
                    startedAt: start.addingTimeInterval(600),
                    endedAt: start.addingTimeInterval(900)
                ),
                RecordingPauseInterval(
                    startedAt: start.addingTimeInterval(1800),
                    endedAt: start.addingTimeInterval(2100)
                ),
            ]
        )

        #expect(seconds == 3000)
    }

    /// A pause the walker never came back from: Stop closes the interval in
    /// the journal, but a session read some other way carries it open, and it
    /// still has to end at the recording rather than run on.
    @Test("an unclosed pause is counted only up to the end of the recording")
    func openPauseEndsWithTheRecording() {
        let endedAt = start.addingTimeInterval(1200)
        let seconds = RecordedWalk.activeSeconds(
            from: start,
            to: endedAt,
            pauses: [
                RecordingPauseInterval(
                    startedAt: start.addingTimeInterval(900),
                    endedAt: nil
                ),
            ]
        )

        #expect(seconds == 900)
    }

    /// Clock corrections and a journal recovered across launches can both put
    /// a boundary outside the span. Neither may hand back more active time
    /// than the recording had, or less than none.
    @Test("a pause outside the recording's own span subtracts nothing extra")
    func pausesAreClampedToTheSpan() {
        let endedAt = start.addingTimeInterval(600)
        let straddling = RecordedWalk.activeSeconds(
            from: start,
            to: endedAt,
            pauses: [
                RecordingPauseInterval(
                    startedAt: start.addingTimeInterval(-3600),
                    endedAt: start.addingTimeInterval(3600)
                ),
            ]
        )
        let outside = RecordedWalk.activeSeconds(
            from: start,
            to: endedAt,
            pauses: [
                RecordingPauseInterval(
                    startedAt: start.addingTimeInterval(-1800),
                    endedAt: start.addingTimeInterval(-900)
                ),
            ]
        )

        #expect(straddling == 0)
        #expect(outside == 600)
    }

    // MARK: The row

    @Test("a saved recording becomes a walk covering the whole of its route")
    func recordedWalkCoversTheWholeRoute() throws {
        let sessionID = UUID()
        let endedAt = start.addingTimeInterval(2400)
        let walk = try #require(
            HikeWalk.recorded(
                metadata(
                    startedAt: start,
                    endedAt: endedAt,
                    pauses: [
                        RecordingPauseInterval(
                            startedAt: start.addingTimeInterval(1200),
                            endedAt: start.addingTimeInterval(1500)
                        ),
                    ],
                    sessionID: sessionID
                ),
                prepared: prepared(startedAt: start, routeLengthMeters: 4200)
            )
        )

        #expect(walk.hikeID == sessionID)
        #expect(walk.startedAt == start)
        #expect(walk.endedAt == endedAt)
        #expect(walk.activeSeconds == 2100)
        #expect(walk.endReason == .recorded)
        #expect(walk.routeDistanceMeters == 4200)
        #expect(walk.furthestDistanceMeters == 4200)
        #expect(walk.coverage.ranges == [0...4200])
        #expect(walk.coveredFraction == 1)
        #expect(walk.uncoveredMeters == 0)
    }

    /// The two ways a recording has no walk to write down. Neither is a
    /// failure — an unfinished session simply has not ended yet, and a route
    /// of no length gives coverage nothing to be a fraction of.
    @Test("a recording with nothing to measure leaves no walk")
    func unmeasurableRecordingsLeaveNoWalk() {
        let unfinished = HikeWalk.recorded(
            metadata(startedAt: start, endedAt: nil),
            prepared: prepared(startedAt: start, routeLengthMeters: 4200)
        )
        let lengthless = HikeWalk.recorded(
            metadata(startedAt: start, endedAt: start.addingTimeInterval(60)),
            prepared: prepared(startedAt: start, routeLengthMeters: 0)
        )

        #expect(unfinished == nil)
        #expect(lengthless == nil)
    }

    /// The invariant `WalkSummaryView` reads a walk against: its stored route
    /// length has to be the length `RouteProfile` measures on the saved row,
    /// or *Show on Map* decides the trail has changed since the walk and
    /// refuses to draw the stretches it covered.
    ///
    /// Which is why the walk is not written against `distanceMeters`: that is
    /// the figure the walker watched tick, with the stationary windows
    /// retracted, and this fixture is built so the two genuinely differ.
    @Test("a recorded walk is measured on the saved route's own length")
    func recordedWalkMatchesTheSavedRoutesProfile() throws {
        let points = wanderingFixture()
        let prepared = try RecordingPreparation.prepare(
            points: points,
            startedAt: start
        )
        let profileLength = RouteProfile(route: prepared.route).totalDistanceMeters

        #expect(abs(prepared.routeLengthMeters - profileLength) < 0.01)
        #expect(
            prepared.routeLengthMeters > prepared.distanceMeters + 50,
            """
            the fixture's stationary window is worth \
            \(prepared.routeLengthMeters) m of line against \
            \(prepared.distanceMeters) m saved — too little for the two rules \
            to disagree about
            """
        )

        let walk = try #require(
            HikeWalk.recorded(
                metadata(
                    startedAt: start,
                    endedAt: start.addingTimeInterval(300)
                ),
                prepared: prepared
            )
        )
        #expect(abs(walk.routeDistanceMeters - profileLength) < 0.01)
        #expect(walk.coveredFraction == 1)
    }
}
