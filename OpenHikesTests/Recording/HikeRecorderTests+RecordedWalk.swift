//
//  HikeRecorderTests+RecordedWalk.swift
//  OpenHikesTests
//
//  What a saved recording leaves in its own History. A recorded hike used to
//  have nothing to show there — the segment exists for walks along a trail,
//  and the recording that *made* the trail was not one of them.
//

import Foundation
@testable import OpenHikes
import SwiftData
import Testing

extension HikeRecorderTests {

    /// Read from a context of its own, so what is asserted is the row the
    /// store accepted rather than a pending edit in the recorder's.
    private func storedWalks() throws -> [HikeWalk] {
        try ModelContext(container).fetch(FetchDescriptor<HikeWalk>())
    }

    @Test("a saved recording writes down the walk it was")
    func savingARecordingWritesItsWalk() async throws {
        let recorder = makeRecorder()
        await recorder.start()
        source.deliver(fix(latitude: 47.63))
        clock.advance(by: 60)
        source.deliver(fix(latitude: 47.631))

        recorder.pause()
        clock.advance(by: 300)
        await recorder.resume()
        source.deliver(fix(latitude: 47.6312))
        clock.advance(by: 60)
        source.deliver(fix(latitude: 47.632))

        let hike = try savedHike(from: await recorder.stop())
        let walks = try storedWalks()
        let walk = try #require(walks.first)

        #expect(walks.count == 1)
        #expect(walk.hikeID == hike.id)
        #expect(walk.hike?.id == hike.id)
        // The whole of the line, because the line is what the walk drew.
        #expect(walk.coveredFraction == 1)
        #expect(walk.endReason == .recorded)
        // Seven minutes on the clock, five of them paused.
        #expect(walk.activeSeconds == 120)
        #expect(walk.startedAt == hike.date)

        // The length the summary compares back against the route it draws —
        // see ``PreparedRecording/routeLengthMeters``.
        let profileLength = RouteProfile(route: hike.route).totalDistanceMeters
        #expect(abs(walk.routeDistanceMeters - profileLength) < 0.01)
    }

    /// The row and the finalized hike are one commit. A store that refuses it
    /// has to leave neither behind, or a retry would write the walk twice.
    @Test("a refused save leaves no walk, and the retry writes exactly one")
    func aRefusedSaveLeavesNoWalk() async throws {
        let saver = ScriptedModelContextSaver(failedSaveNumbers: [2])
        let recorder = makeRecorder(saveModelContext: saver.save)
        await recorder.start()
        source.deliver(fix(latitude: 47.63))
        clock.advance(by: 60)
        source.deliver(fix(latitude: 47.631))

        await #expect(throws: RecordingFailure.self) {
            try await recorder.stop()
        }
        let afterRefusal = try storedWalks()
        #expect(afterRefusal.isEmpty)

        let hike = try await recorder.retrySave()
        let walks = try storedWalks()

        #expect(walks.count == 1)
        #expect(walks.first?.hikeID == hike.id)
        #expect(walks.first?.endReason == .recorded)
    }
}
