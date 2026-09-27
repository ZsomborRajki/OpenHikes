//
//  HikeRecorderTests+FixWindow.swift
//  OpenHikesTests
//
//  Live fixes taken before the recording, or its current leg, began (#749).
//  Every fix refused here is inside `RecordingFixPolicy`'s thirty-second
//  freshness window, and every approach is long enough that the heartbeat
//  escape would have admitted the jump to the first real fix — so without
//  ``RecordingFixWindow`` each of these walks is a kilometre longer.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import RealModule
import SwiftData
import Testing

extension HikeRecorderTests {
    @Test("a cached fix from before Start neither opens the trace nor adds its approach")
    func cachedFixBeforeStartIsRefused() async throws {
        let hikeRecorder = makeRecorder()
        let startedAt = clock.now
        await hikeRecorder.start()

        // The issue's reproduction: good accuracy, twenty seconds old, and a
        // kilometre short of where the walk actually starts.
        source.deliver(fix(latitude: 47.62, takenAt: startedAt.addingTimeInterval(-20)))
        #expect(hikeRecorder.stats.pointCount == 0)
        #expect(hikeRecorder.lastAcceptedPoint == nil)
        #expect(hikeRecorder.phase == .waitingForFix)

        source.deliver(fix(latitude: 47.63))
        clock.advance(by: 10)
        source.deliver(fix(latitude: 47.6302))

        let hike = try savedHike(from: await hikeRecorder.stop())
        #expect(hike.route.count == 2)
        #expect(hike.route.allSatisfy { ($0.timestamp ?? .distantPast) >= startedAt })
        #expect(hike.distanceMeters.isApproximatelyEqual(to: 22, absoluteTolerance: 5))
    }

    @Test("a batch straddling Start keeps only what was taken after it")
    func batchStraddlingStartKeepsTheRecording() async throws {
        let hikeRecorder = makeRecorder()
        let startedAt = clock.now
        await hikeRecorder.start()
        clock.advance(by: 10)

        source.deliver([
            fix(latitude: 47.62, takenAt: startedAt.addingTimeInterval(-15)),
            fix(latitude: 47.63, takenAt: startedAt),
            fix(latitude: 47.6302, takenAt: startedAt.addingTimeInterval(10)),
        ])

        #expect(hikeRecorder.stats.pointCount == 2)
        let hike = try savedHike(from: await hikeRecorder.stop())
        #expect(hike.route.first?.timestamp == startedAt)
        #expect(hike.distanceMeters.isApproximatelyEqual(to: 22, absoluteTolerance: 5))
    }

    @Test("a late batch taken during the recording is kept whole")
    func delayedInSessionBatchIsKept() async throws {
        let hikeRecorder = makeRecorder()
        let startedAt = clock.now
        await hikeRecorder.start()
        // Taken at 0 s, 10 s and 20 s; delivered together at 25 s, the way a
        // backgrounded feed batches. The timestamps are what the window reads.
        clock.advance(by: 25)
        source.deliver([
            fix(latitude: 47.63, takenAt: startedAt),
            fix(latitude: 47.6302, takenAt: startedAt.addingTimeInterval(10)),
            fix(latitude: 47.6304, takenAt: startedAt.addingTimeInterval(20)),
        ])

        #expect(hikeRecorder.stats.pointCount == 3)
        let hike = try savedHike(from: await hikeRecorder.stop())
        #expect(hike.distanceMeters.isApproximatelyEqual(to: 44, absoluteTolerance: 5))
    }

    @Test("a fix taken during a pause does not open the leg after the resume")
    func fixFromThePauseIsRefusedAfterResume() async throws {
        let hikeRecorder = makeRecorder()
        await hikeRecorder.start()
        source.deliver(fix(latitude: 47.63))
        clock.advance(by: 60)
        source.deliver(fix(latitude: 47.631))

        hikeRecorder.pause()
        clock.advance(by: 300)
        let resumedAt = clock.now
        await hikeRecorder.resume()
        // Walked on while paused: the batch delivered after the resume still
        // holds a fix from fifteen seconds before it, half a kilometre short
        // of where the new leg really starts.
        source.deliver([
            fix(latitude: 47.635, takenAt: resumedAt.addingTimeInterval(-15)),
            fix(latitude: 47.64, takenAt: resumedAt),
        ])
        clock.advance(by: 60)
        source.deliver(fix(latitude: 47.641))

        let hike = try savedHike(from: await hikeRecorder.stop())
        #expect(hike.route.count == 4)
        #expect(hike.distanceMeters.isApproximatelyEqual(to: 222, absoluteTolerance: 5))
    }

    @Test("a recovered leg keeps the window the journal says it opened at")
    func recoveredLegOpensAtTheJournalsResume() async throws {
        let journal = TrackJournal(directory: directory, clock: clock.read)
        try await journal.start(sessionID: UUID(), startedAt: clock.now)
        clock.advance(by: 10)
        try await journal.pause(at: clock.now)
        clock.advance(by: 30)
        let resumedAt = clock.now
        try await journal.resume(at: resumedAt)
        try await journal.close()

        let hikeRecorder = makeRecorder()
        await hikeRecorder.recoverOpenSession()
        #expect(hikeRecorder.phase == .waitingForFix)

        source.deliver(fix(latitude: 47.62, takenAt: resumedAt.addingTimeInterval(-15)))
        #expect(hikeRecorder.stats.pointCount == 0)
        source.deliver(fix(latitude: 47.63))
        #expect(hikeRecorder.stats.pointCount == 1)
        #expect(hikeRecorder.lastAcceptedPoint?.timestamp == resumedAt)
    }

    /// ``fix(latitude:longitude:accuracy:speed:)``, taken at `timestamp`
    /// rather than at the clock's now.
    private func fix(latitude: Double, takenAt timestamp: Date) -> CLLocation {
        let current = fix(latitude: latitude)
        return CLLocation(
            coordinate: current.coordinate,
            altitude: current.altitude,
            horizontalAccuracy: current.horizontalAccuracy,
            verticalAccuracy: current.verticalAccuracy,
            course: current.course,
            speed: current.speed,
            timestamp: timestamp
        )
    }
}
