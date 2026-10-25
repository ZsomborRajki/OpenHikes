//
//  HikeRecorderTests+StoredClock.swift
//  OpenHikesTests
//
//  The clock a saved recording keeps on its row, which Siri, Spotlight and
//  the widget's catalogue read instead of decoding the route (#1025). Stop
//  writes the route into the draft in place, so a refused save is the case
//  worth having: it puts the draft's empty route back, and has to take the
//  clock with it, or the draft would carry a clock for a line it no longer
//  has.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import Testing

extension HikeRecorderTests {
    @Test("a saved recording keeps its clock, first fix to last, pauses and all")
    func aSavedRecordingKeepsItsClock() async throws {
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

        // Seven minutes from the first fix to the last, five of them paused:
        // the *Duration* the hike's own screen works out from its route.
        #expect(hike.durationSeconds == 420)
        #expect(hike.durationSeconds == hike.routeStatistics.duration)
    }

    @Test("a refused save takes the clock back off the draft with its route")
    func aRefusedSaveTakesTheClockBack() async throws {
        let saver = ScriptedModelContextSaver(failedSaveNumbers: [2])
        let recorder = makeRecorder(saveModelContext: saver.save)
        await recorder.start()
        let draft = try #require(recorder.currentHike)
        source.deliver(fix(latitude: 47.63))
        clock.advance(by: 60)
        source.deliver(fix(latitude: 47.631))

        await #expect(throws: RecordingFailure.self) {
            try await recorder.stop()
        }
        #expect(draft.isRecording)
        #expect(draft.route.isEmpty)
        #expect(draft.durationSeconds == nil)

        let hike = try await recorder.retrySave()

        #expect(hike.id == draft.id)
        #expect(hike.durationSeconds == 60)
    }
}
