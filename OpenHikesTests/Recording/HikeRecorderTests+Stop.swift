//
//  HikeRecorderTests+Stop.swift
//  OpenHikesTests
//
//  What a tap on Stop does first, read off a real recording: the rule is
//  ``RecordingStopStep``'s, pinned in `RecordingStopTests.swift`, and these
//  hold the recorder to feeding it the recording as it stands — its kept
//  points, the fixes still on their way to its journal, and what the hiker
//  has put on its draft.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import OpenHikesShared
import SwiftData
import Testing

extension HikeRecorderTests {
    @Test("a recording still finding GPS is ended by Stop without a question")
    func stopEndsARecordingWithNoFix() async {
        let recorder = makeRecorder()
        await recorder.start()

        #expect(recorder.phase == .waitingForFix)
        #expect(await recorder.settledStopStep() == .endEmpty)
    }

    /// One point is a place, not a line: the save would refuse it.
    @Test("a recording with one point is ended by Stop without a question")
    func stopEndsARecordingWithOnePoint() async {
        let recorder = makeRecorder()
        await recorder.start()
        source.deliver(fix(latitude: 47.63))

        #expect(recorder.stats.pointCount == 1)
        #expect(await recorder.settledStopStep() == .endEmpty)
    }

    @Test("a recording with a line is asked for its name")
    func stopNamesARecordingWithALine() async {
        let recorder = makeRecorder()
        await recorder.start()
        source.deliver(fix(latitude: 47.63))
        clock.advance(by: 60)
        source.deliver(fix(latitude: 47.631))

        #expect(await recorder.settledStopStep() == .askName)
    }

    /// The widget's fix is a fix the walk has, waiting in the App Group for
    /// the next merge: with the phone's one it is a line, which `stop()`
    /// merges and saves. Ending the recording on the live count threw both
    /// away.
    @Test("a fix the widget still holds is counted before Stop calls a recording empty")
    func stopCountsTheWidgetsWaitingFix() async throws {
        let sharedStore = StubRecordingSharedStateStore()
        let recorder = makeRecorder(sharedStateStore: sharedStore)
        await recorder.start()
        source.deliver(fix(latitude: 47.63))
        let sessionID = try #require(recorder.sessionID)
        let journal = try #require(recorder.journal)
        // The merge the fix scheduled, finished before the widget's fix is
        // staged, so the live figures cannot have heard of it below.
        await recorder.pendingFixMergeTask?.value
        // Twenty seconds clear of the phone's, so normalization keeps both.
        await sharedStore.setPendingFixes([
            SharedRecordingFix(
                sessionID: sessionID,
                latitude: 47.6306,
                longitude: 12.86,
                timestamp: clock.now.addingTimeInterval(20),
                horizontalAccuracy: 20
            ),
        ])
        #expect(recorder.stopStep == .endEmpty, "the live figures have one point")

        #expect(await recorder.settledStopStep() == .askName)
        #expect(recorder.phase == .recording, "counting ends nothing")
        #expect(try #require(await journal.loadSession()).points.count == 2)
    }

    @Test("a second tap on Stop while the first is counting is not a second stop")
    func stopIgnoresATapWhileCounting() async {
        let recorder = makeRecorder()
        await recorder.start()
        source.deliver(fix(latitude: 47.63))
        recorder.isSettlingStop = true

        #expect(await recorder.settledStopStep() == nil)
        recorder.isSettlingStop = false
        #expect(await recorder.settledStopStep() == .endEmpty)
    }

    @Test("a recording that has ended is not stopped again")
    func stopAsksNothingOfAnEndedRecording() async {
        let recorder = makeRecorder()
        await recorder.start()
        source.deliver(fix(latitude: 47.63))
        await recorder.discard()

        #expect(await recorder.settledStopStep() == nil)
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

        #expect(await recorder.settledStopStep() == .confirmDiscard)
    }

    /// What Stop then does with it: the recorder is idle again and the draft
    /// row is gone, as after a discard from a pause.
    @Test("ending an empty recording leaves no draft behind")
    func endingAnEmptyRecordingLeavesNothing() async throws {
        let recorder = makeRecorder()
        await recorder.start()
        source.deliver(fix(latitude: 47.63))
        #expect(await recorder.settledStopStep() == .endEmpty)

        await recorder.discard()

        #expect(recorder.phase == .idle)
        #expect(try context.fetch(FetchDescriptor<Hike>()).isEmpty)
    }
}
