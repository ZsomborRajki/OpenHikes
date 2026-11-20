//
//  HikeRecorderTests+Stop.swift
//  OpenHikesTests
//
//  What a tap on Stop does first, read off a real recording: the rule is
//  ``RecordingStopStep``'s, pinned in `RecordingStopTests.swift`, and these
//  hold the recorder to feeding it the recording as it stands — its kept
//  points, and what the hiker has put on its draft.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import SwiftData
import Testing

extension HikeRecorderTests {
    @Test("a recording still finding GPS is ended by Stop without a question")
    func stopEndsARecordingWithNoFix() async {
        let recorder = makeRecorder()
        await recorder.start()

        #expect(recorder.phase == .waitingForFix)
        #expect(recorder.stopStep == .endEmpty)
    }

    /// One point is a place, not a line: the save would refuse it.
    @Test("a recording with one point is ended by Stop without a question")
    func stopEndsARecordingWithOnePoint() async {
        let recorder = makeRecorder()
        await recorder.start()
        source.deliver(fix(latitude: 47.63))

        #expect(recorder.stats.pointCount == 1)
        #expect(recorder.stopStep == .endEmpty)
    }

    @Test("a recording with a line is asked for its name")
    func stopNamesARecordingWithALine() async {
        let recorder = makeRecorder()
        await recorder.start()
        source.deliver(fix(latitude: 47.63))
        clock.advance(by: 60)
        source.deliver(fix(latitude: 47.631))

        #expect(recorder.stopStep == .askName)
    }

    /// Marked at the trailhead, before the walk had gone anywhere.
    @Test("a place on a recording with no line is asked about before it goes")
    func stopAsksAboutAPlaceOnAShortRecording() async throws {
        let recorder = makeRecorder()
        await recorder.start()
        source.deliver(fix(latitude: 47.63))
        let draft = try #require(recorder.currentHike)
        try HikePlaceChange.add(
            TrailPlace(latitude: 47.63, longitude: 12.86, symbol: .viewpoint),
            to: draft,
            in: container.mainContext
        )

        #expect(recorder.stopStep == .confirmDiscard)
    }

    /// What Stop then does with it: the recorder is idle again and the draft
    /// row is gone, as after a discard from a pause.
    @Test("ending an empty recording leaves no draft behind")
    func endingAnEmptyRecordingLeavesNothing() async throws {
        let recorder = makeRecorder()
        await recorder.start()
        source.deliver(fix(latitude: 47.63))
        #expect(recorder.stopStep == .endEmpty)

        await recorder.discard()

        #expect(recorder.phase == .idle)
        #expect(try context.fetch(FetchDescriptor<Hike>()).isEmpty)
    }
}
