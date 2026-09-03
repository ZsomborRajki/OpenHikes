//
//  PauseBoundaryTests.swift
//  OpenHikesTests
//
//  What a pause leaves behind once the recording it happened in is over.
//
//  The recorder has always known about pauses — the matcher refuses to bridge
//  across one, the distance accumulator restarts its clock at one — but the
//  saved route used to keep none of that, so a walk with an hour's lunch in it
//  came back as one unbroken line. These are the four places that fact now has
//  to survive to: the persisted route, the drawn line, the elevation profile,
//  and the live readout that has to agree with all three.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import Testing

@Suite("Pause boundaries")
struct PauseBoundaryTests {
    private let start = Date(timeIntervalSince1970: 1_750_000_000)

    /// Two fixes a minute apart, an hour's pause a kilometre away, then two
    /// more. Far enough that a line drawn straight across the pause is
    /// obviously not a walk, which is the case every assertion here is about.
    private func pausedWalk() -> [RecordingPoint] {
        [
            point(latitude: 47.63, offset: 0),
            point(latitude: 47.631, offset: 60),
            point(latitude: 47.64, offset: 3660, flags: .resumed),
            point(latitude: 47.641, offset: 3720),
        ]
    }

    private func point(
        latitude: Double,
        offset: TimeInterval,
        flags: RecordingPointFlags = []
    ) -> RecordingPoint {
        RecordingPoint(
            latitude: latitude,
            longitude: 12.86,
            timestamp: start.addingTimeInterval(offset),
            horizontalAccuracy: 8,
            elevation: 600,
            flags: flags
        )
    }

    /// The flag the recorder writes is live state; the boundary is what
    /// outlives the recording. Nothing else in a saved hike could reconstruct
    /// it — a long leg is equally what a phone in a pack produces.
    @Test("a resumed fix is saved as a pause boundary")
    func resumeIsPersisted() throws {
        let prepared = try RecordingPreparation.prepare(
            points: pausedWalk(),
            startedAt: start
        )

        #expect(prepared.route.map(\.isPauseBoundary) == [false, false, true, false])
        // A pause is the walker's decision, not the app's guess, so the route
        // claims nothing was inferred across it.
        #expect(!prepared.route.containsInferredGeometry)
    }

    @Test("a walk recorded without a pause carries no boundary")
    func unpausedWalkHasNoBoundary() throws {
        let points = [
            point(latitude: 47.63, offset: 0),
            point(latitude: 47.631, offset: 60),
            point(latitude: 47.632, offset: 120),
        ]

        let prepared = try RecordingPreparation.prepare(
            points: points,
            startedAt: start
        )

        #expect(!prepared.route.containsPause)
    }

    /// The map draws the pause as its own overlay, so the boundary has to
    /// resolve to the leg that crosses it — the last fix before the pause and
    /// the first one after — rather than to a lone point floating beside the
    /// line.
    @Test("the drawn pause is the leg from the last fix to the first after it")
    func pausedSegmentSpansTheLeg() throws {
        let prepared = try RecordingPreparation.prepare(
            points: pausedWalk(),
            startedAt: start
        )

        let segments = prepared.route.pausedSegments
        #expect(segments.count == 1)
        let segment = try #require(segments.first)
        #expect(segment.count == 2)
        #expect(segment[0].latitude == 47.631)
        #expect(segment[1].latitude == 47.64)
        #expect(prepared.route.containsPause)
    }

    /// The profile keeps its x-axis continuous across a pause — no distance
    /// went missing, only time — so what the chart needs is where along the
    /// route to draw the rule.
    @Test("the elevation profile records where the pause fell")
    func profileCarriesPauseDistance() throws {
        let prepared = try RecordingPreparation.prepare(
            points: pausedWalk(),
            startedAt: start
        )
        let profile = RouteProfile(route: prepared.route)

        #expect(profile.pauseDistances.count == 1)
        let distance = try #require(profile.pauseDistances.first)
        let total = try #require(profile.distances.last)
        // The pause opens after ~111 m of walking and spans ~1 km, so the rule
        // belongs at the far end of that leg rather than at its start — and
        // inside the route it annotates.
        #expect(distance > 1000)
        #expect(distance < total)
    }

    /// A boundary never lands on the first point of a route: it describes the
    /// leg arriving at a point, and the first one arrives from nowhere. The
    /// recorder can produce this — pause before the first fix ever lands, then
    /// resume — and everything downstream indexes from 1 on that promise.
    @Test("a resume before the first fix marks nothing")
    func resumeOnTheFirstFixIsNotABoundary() {
        let route = [
            RouteCoordinate(latitude: 47.63, longitude: 12.86, boundary: .paused),
            RouteCoordinate(latitude: 47.64, longitude: 12.86),
        ]

        #expect(!route.containsPause)
        #expect(route.pausedSegments.isEmpty)
        #expect(RouteProfile(route: route).pauseDistances.isEmpty)
    }

    /// The live readout and the saved hike are meant to be the same number,
    /// which is why they are the same accumulator. Restarting that accumulator
    /// at a resume — rather than restarting only what it measures across —
    /// dropped every second walked before the pause, so a walker who stopped
    /// for lunch watched their morning's moving time go back to zero.
    @Test("a pause keeps the moving time already walked")
    func pauseKeepsMovingTimeAlreadyWalked() {
        var accumulator = RecordingDistanceAccumulator()
        // Ten minutes of steady walking, one point a second, so the moving
        // clock has something substantial to lose.
        let metersPerDegree = 2 * Double.pi * 6_371_008.8 / 360
        var latitude = 47.63
        for second in 0...600 {
            accumulator.append(
                point(latitude: latitude, offset: Double(second))
            )
            latitude += 1.4 / metersPerDegree
        }
        let beforePause = accumulator.movingSeconds
        #expect(beforePause > 300)

        accumulator.append(
            point(latitude: latitude + 0.01, offset: 4200, flags: .resumed)
        )

        #expect(accumulator.movingSeconds == beforePause)
    }
}
