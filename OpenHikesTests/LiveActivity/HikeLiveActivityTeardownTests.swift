//
//  HikeLiveActivityTeardownTests.swift
//  OpenHikesTests
//
//  "Hike Live Activity teardown", split out of
//  HikeLiveActivityControllerTests.swift so that a file declares one @Suite.
//  That file's header still holds the context the two share.
//

import Foundation
@testable import OpenHikes
import OpenHikesShared
import Testing

/// The other half of the controller's job, split from
/// ``HikeLiveActivityControllerTests`` for length. Everything either suite
/// needs lives in ``LiveActivityHarness``.
@MainActor
@Suite("Hike Live Activity teardown")
struct HikeLiveActivityTeardownTests {
    @Test("ending the running subject takes it down")
    func endingTheRunningSubject() async {
        let harness = LiveActivityHarness.harness()
        harness.controller.update(LiveActivityHarness.recordingRequest())
        await harness.controller.settle()

        harness.controller.end(
            subject: .recording(sessionID: LiveActivityHarness.sessionID),
            finalState: LiveActivityHarness.recordingRequest(runState: .finished).state,
            dismissAfter: HikeLiveActivityController.finishedDismissAfter
        )
        await harness.controller.settle()
        #expect(harness.controller.activeSubject == nil)
        #expect(
            harness.presenter.calls.last == .end(
                finalState: LiveActivityHarness.recordingRequest(runState: .finished).state,
                dismissAfter: HikeLiveActivityController.finishedDismissAfter
            )
        )
    }

    /// A follow ending while a recording holds the screen must not take the
    /// recording down with it — which is exactly what an unguarded end would
    /// do, because both callers fire for walks that already lost the screen.
    @Test("ending a subject that is not on screen does nothing")
    func endingAnInactiveSubjectDoesNothing() async {
        let harness = LiveActivityHarness.harness()
        harness.controller.update(LiveActivityHarness.recordingRequest())
        await harness.controller.settle()

        harness.controller.end(subject: .following(hikeID: LiveActivityHarness.hikeID))
        await harness.controller.settle()
        #expect(harness.controller.activeSubject == .recording(sessionID: LiveActivityHarness.sessionID))
        #expect(harness.presenter.endCount == 0)
    }

    @Test("ending everything leaves nothing running")
    func endAllTakesWhateverIsUp() async {
        let harness = LiveActivityHarness.harness()
        harness.controller.update(LiveActivityHarness.followingRequest())
        await harness.controller.settle()

        harness.controller.endAll()
        await harness.controller.settle()
        #expect(harness.controller.activeSubject == nil)
        #expect(harness.presenter.endCount == 1)
    }

    /// A second end is not a second call. Both recording teardown paths run
    /// beside a shared-state clear that can itself return early, so an
    /// idempotent end is what stops a retry from ending an activity that
    /// belongs to the next walk.
    @Test("ending twice ends once")
    func endingIsIdempotent() async {
        let harness = LiveActivityHarness.harness()
        harness.controller.update(LiveActivityHarness.recordingRequest())
        await harness.controller.settle()

        harness.controller.endAll()
        harness.controller.endAll()
        await harness.controller.settle()
        #expect(harness.presenter.endCount == 1)
    }

    /// A restart after an end is a fresh activity, not a resumed one — and it
    /// must not inherit the previous walk's throttle, or the first thing the
    /// hiker sees would be up to twenty seconds stale.
    @Test("a new walk after an end starts immediately")
    func restartingIsNotThrottled() async {
        let harness = LiveActivityHarness.harness()
        harness.controller.update(LiveActivityHarness.recordingRequest())
        await harness.controller.settle()
        harness.controller.endAll()
        await harness.controller.settle()

        harness.now.date = LiveActivityHarness.start.addingTimeInterval(1)
        harness.controller.update(LiveActivityHarness.followingRequest(at: harness.now.date))
        await harness.controller.settle()
        #expect(harness.presenter.startedSubjects.count == 2)
        #expect(harness.controller.activeSubject == .following(hikeID: LiveActivityHarness.hikeID))
    }

    // MARK: Staleness

    /// A recording updates once a fix, so silence means the fixes stopped. A
    /// follow is throttled to significant-change events in the background, so
    /// the same silence is an ordinary walk in a valley.
    @Test("the two subjects go stale on different terms")
    func staleDatesDifferBySubject() async {
        let harness = LiveActivityHarness.harness()
        harness.controller.update(LiveActivityHarness.recordingRequest())
        await harness.controller.settle()
        #expect(
            harness.presenter.staleIntervals.last
                == HikeLiveActivityController.recordingStaleAfter
        )

        harness.controller.endAll()
        await harness.controller.settle()
        harness.controller.update(LiveActivityHarness.followingRequest())
        await harness.controller.settle()
        #expect(
            harness.presenter.staleIntervals.last
                == HikeLiveActivityController.followingStaleAfter
        )
    }
}
