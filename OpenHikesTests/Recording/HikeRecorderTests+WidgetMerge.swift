//
//  HikeRecorderTests+WidgetMerge.swift
//  OpenHikesTests
//
//  What happens after fixes captured by the widget are folded back into a
//  running recording: the live stats and trace have to be rebuilt from the
//  journal that now holds both sources, and that rebuild has to end.
//
//  It is the one path in the recorder whose cost is O(points) *and* that
//  restarts when a fix lands while it is running, so it is the one place where
//  a longer hike makes a retry both more expensive and more likely.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import SwiftData
import Testing

extension HikeRecorderTests {

    /// The refresh that follows a widget merge re-reads the whole session from
    /// disk and re-normalizes every point, and starts over when a fix is
    /// accepted while it is doing so. That is O(points) of work per attempt, so
    /// the window it occupies widens as the hike gets longer — which makes
    /// another fix landing inside it *more* likely the longer the recording
    /// runs. Uncapped, that is a retry whose cost and failure probability both
    /// climb together.
    ///
    /// This drives the pathological case directly: fixes keep arriving for as
    /// long as the refresh is running. What is asserted is that it comes back
    /// at all, and that the recording is still healthy when it does — the loop
    /// this replaced had no exit other than the session ending.
    ///
    /// The `.timeLimit` is the real assertion. A regression here does not fail
    /// an expectation; it never returns.
    @Test(
        "a merge refresh stops retrying rather than chasing a moving revision",
        .timeLimit(.minutes(1))
    )
    func journalMergeRefreshIsBounded() async throws {
        let recorder = makeRecorder()
        await recorder.start()
        source.deliver(fix(latitude: 47.63))
        let journal = try #require(recorder.journal)
        let sessionID = try #require(recorder.sessionID)

        let pressure = Task { @MainActor in
            var latitude = 47.6302
            while !Task.isCancelled {
                clock.advance(by: 30)
                source.deliver(fix(latitude: latitude))
                latitude += 0.0002
                await Task.yield()
            }
        }
        await recorder.refreshLiveStateAfterJournalMerge(
            expectedSessionID: sessionID,
            journal: journal
        )
        pressure.cancel()

        #expect(HikeRecorder.journalMergeRefreshAttemptLimit > 0)
        #expect(recorder.phase == .recording)
        #expect(recorder.stats.pointCount >= 1)
    }

    /// Giving up has to leave the recording untouched rather than half-rebuilt:
    /// the merged points are already durable in the journal, so the fallback is
    /// simply the live state that was there before — and the next accepted fix
    /// rebuilds from the merged journal anyway.
    @Test("a merge refresh with no contention rebuilds from the journal")
    func journalMergeRefreshRebuildsLiveState() async throws {
        let recorder = makeRecorder()
        await recorder.start()
        source.deliver(fix(latitude: 47.63))
        clock.advance(by: 40)
        source.deliver(fix(latitude: 47.6304))
        let journal = try #require(recorder.journal)
        let sessionID = try #require(recorder.sessionID)
        let before = recorder.stats.pointCount

        await recorder.refreshLiveStateAfterJournalMerge(
            expectedSessionID: sessionID,
            journal: journal
        )

        #expect(recorder.stats.pointCount == before)
        #expect(recorder.phase == .recording)
    }
}
