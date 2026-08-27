//
//  HikeRecorderTests+MergeRetry.swift
//  OpenHikesTests
//
//  What the merge refresh does when it runs out of attempts.
//
//  `refreshLiveStateAfterJournalMerge` re-reads the whole session from disk and
//  re-normalizes it, then throws that work away and starts over if a fix was
//  accepted while it was running — three times, and then it stops. The cap is
//  the interesting part: the work is O(points), so the window a fix can land
//  inside widens as the walk gets longer, and an uncapped loop would retry more
//  often exactly when each retry costs most.
//
//  `HikeRecorderTests+WidgetMerge.swift` pins that the loop *terminates* under
//  sustained contention. This pins what terminating leaves behind, which is the
//  half a walker would notice: the merged fixes are durable in the journal
//  either way, and the live state either adopted them or kept the values it
//  already had. Both branches are driven here, one after the other on the same
//  recording, so the give-up assertion cannot pass because the fixture had
//  nothing to adopt in the first place.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesShared
import SwiftData
import Testing

extension HikeRecorderTests {

    /// The guard the retry turns on is `acceptedFixRevision == revision`, read
    /// after an off-main round trip, so contention is simulated by moving that
    /// value rather than by delivering fixes: a delivered fix would also change
    /// the live stats this test is asserting on, and the whole question is
    /// whether the live stats moved.
    ///
    /// The `.timeLimit` is not decoration. With the contention running for as
    /// long as the refresh does, a refresh that lost its cap never returns.
    @Test(
        "a refresh that never sees a quiet moment gives up without losing the merge",
        .timeLimit(.minutes(1))
    )
    func journalMergeRefreshGivesUpAndKeepsThePreMergeState() async throws {
        let sharedStore = StubRecordingSharedStateStore()
        let recorder = makeRecorder(sharedStateStore: sharedStore)
        await recorder.start()
        source.deliver(fix(latitude: 47.63))
        clock.advance(by: 40)
        source.deliver(fix(latitude: 47.6304))
        let sessionID = try #require(recorder.sessionID)
        let journal = try #require(recorder.journal)

        // Every accepted fix schedules a merge of its own, and one of those is
        // still in flight here. Left alone it would race the merge under test
        // for the same staged fix — and the loser returns early, having
        // asserted nothing. Awaiting it first means it finds an empty store,
        // and the only merge that sees the fix below is the one being driven.
        await recorder.pendingFixMergeTask?.value

        // Twenty seconds clear of both live fixes, so normalization's
        // five-second deduplication keeps it and the merge is worth one point.
        await sharedStore.setPendingFixes([
            SharedRecordingFix(
                sessionID: sessionID,
                latitude: 47.6306,
                longitude: 12.86,
                timestamp: clock.now.addingTimeInterval(20),
                horizontalAccuracy: 60
            ),
        ])
        await recorder.sharedStateQueue.drain()
        let liveBefore = recorder.stats.pointCount
        let snapshotsBefore = await sharedStore.savedSnapshots().count

        let contention = Task { @MainActor in
            while !Task.isCancelled {
                recorder.acceptedFixRevision &+= 1
                await Task.yield()
            }
        }
        await recorder.mergePendingWidgetFixes(for: sessionID)
        contention.cancel()
        await recorder.sharedStateQueue.drain()

        #expect(recorder.stats.pointCount == liveBefore, "the live state kept its pre-merge value")
        #expect(recorder.trace.tail.count == liveBefore, "and so did the line the map is drawing")
        #expect(
            await sharedStore.savedSnapshots().count == snapshotsBefore,
            "the forced snapshot belongs to the success branch, which was never reached"
        )
        #expect(recorder.phase == .recording, "giving up is not a failure state")

        // Nothing was lost by giving up: the widget's fix is on disk, and the
        // very next accepted fix rebuilds from the journal that now holds it.
        let mergedSession = try #require(await journal.loadSession())
        #expect(mergedSession.points.count == liveBefore + 1)

        // The same refresh, on the same journal, with nothing moving under it.
        // This is what makes the four assertions above a finding rather than a
        // fixture that had nothing to adopt.
        await recorder.refreshLiveStateAfterJournalMerge(
            expectedSessionID: sessionID,
            journal: journal
        )
        await recorder.sharedStateQueue.drain()

        #expect(recorder.stats.pointCount == liveBefore + 1)
        #expect(recorder.trace.tail.count == liveBefore + 1)
        #expect(await sharedStore.savedSnapshots().count == snapshotsBefore + 1)
    }
}
