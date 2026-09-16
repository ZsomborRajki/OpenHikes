//
//  OrphanedActivityTests.swift
//  OpenHikesTests
//
//  Taking down a Live Activity this process did not start.
//
//  A Live Activity outlives the process that requested it, so after the app is
//  killed mid-hike the hiker's next launch begins with a panel on the Lock
//  Screen that no object in the app holds a handle to. `end(subject:)` and
//  `endAll()` both open by consulting `current`, which is `nil` in a fresh
//  process, so every takedown path was a no-op against exactly the panel that
//  most needed taking down — it then sat for its full ten-minute stale window
//  reporting a walk that no longer exists.
//
//  What is pinned here is `endUnowned(_:)` and its three guards. The sweep has
//  to fire when there is an orphan of the right kind, and must not fire when
//  there is nothing running, when the orphan is a *follow* the hiker is still
//  on, or when this process owns the panel and can end it properly instead.
//

import Foundation
@testable import OpenHikes
import OpenHikesShared
import Testing
import UIKit

@Suite("Hike Live Activity orphan takedown")
@MainActor
struct OrphanedActivityTests {
    /// The whole point of the fix. Nothing in this process started the panel —
    /// `simulatePreviousLaunch` records no `start` — and it still comes down.
    ///
    /// Goes red if `enqueue { await presenter.endUnowned(kind) }` is deleted
    /// from `HikeLiveActivityController.endUnowned(_:)`, and also if that
    /// `enqueue` is replaced by a bare `Task {}`, since `settle()` drains
    /// `pendingWork` and would not wait for one.
    @Test("a recording left by a previous launch is taken down")
    func orphanedRecordingIsTakenDown() async {
        let harness = LiveActivityHarness.harness()
        harness.presenter.simulatePreviousLaunch(
            .recording(sessionID: LiveActivityHarness.sessionID)
        )
        #expect(
            harness.controller.activeSubject == nil,
            "the point of the scenario is that this process owns nothing"
        )

        harness.controller.endUnowned(.recording)
        await harness.controller.settle()

        #expect(harness.presenter.endUnownedKinds == [.recording])
        #expect(harness.presenter.activeSubject == nil)
    }

    /// The ordinary case, which every failing and discarding path in the
    /// recorder now runs through: nothing is on screen, so the sweep costs one
    /// property read and no framework call.
    ///
    /// Goes red if `guard kind.matches(presenter.activeSubject) else { return }`
    /// is deleted from `HikeLiveActivityController.endUnowned(_:)`.
    @Test("nothing running is not swept")
    func nothingRunningIsNotSwept() async {
        let harness = LiveActivityHarness.harness()

        harness.controller.endUnowned(.recording)
        await harness.controller.settle()

        #expect(harness.presenter.calls.isEmpty)
    }

    /// Precedence, read from the takedown end. A followed trail from the
    /// previous launch is still a walk the hiker is on — the tracker adopts
    /// it back on the next matched fix — so a *recording* turning out not to
    /// exist must not remove it.
    ///
    /// Goes red if `HikeActivityKind.matches(_:)`'s `case .recording` returns
    /// anything less specific than `subject.isRecording` — `true`, say — or if
    /// the sweep is made unconditional over every running activity.
    @Test("a followed trail survives a recording takedown")
    func followIsNotSweptByARecordingTakedown() async {
        let harness = LiveActivityHarness.harness()
        harness.presenter.simulatePreviousLaunch(
            .following(hikeID: LiveActivityHarness.hikeID)
        )

        harness.controller.endUnowned(.recording)
        await harness.controller.settle()

        #expect(harness.presenter.calls.isEmpty)
        #expect(
            harness.presenter.activeSubject == .following(hikeID: LiveActivityHarness.hikeID)
        )
    }

    /// The converse of the one above, so the targeting is shown to work in
    /// both directions rather than only to refuse.
    ///
    /// Goes red under the same mutation as
    /// ``orphanedRecordingIsTakenDown()``, and additionally if
    /// `HikeActivityKind.matches(_:)`'s `case .following` is made to read
    /// `subject.isRecording`.
    @Test("a followed trail left by a previous launch can be taken down on purpose")
    func orphanedFollowIsTakenDownWhenAsked() async {
        let harness = LiveActivityHarness.harness()
        harness.presenter.simulatePreviousLaunch(
            .following(hikeID: LiveActivityHarness.hikeID)
        )

        harness.controller.endUnowned(.following)
        await harness.controller.settle()

        #expect(harness.presenter.endUnownedKinds == [.following])
        #expect(harness.presenter.activeSubject == nil)
    }

    /// When this process *is* presenting the recording, the sweep must stand
    /// aside: `end(subject:finalState:dismissAfter:)` is the path that can
    /// leave a finished walk's totals on screen for five minutes, and this one
    /// cannot. Without the guard, `endRecordingActivity(.finished)` — which
    /// reaches the sweep on any path where the subject reads as unowned —
    /// could remove the panel the hiker was meant to read.
    ///
    /// Goes red if `guard !kind.matches(current?.attributes.subject) else { return }`
    /// is deleted from `HikeLiveActivityController.endUnowned(_:)`.
    @Test("a recording this process owns is left to the ordinary end path")
    func ownedRecordingIsNotSwept() async {
        let harness = LiveActivityHarness.harness()
        harness.controller.update(LiveActivityHarness.recordingRequest())
        await harness.controller.settle()
        #expect(harness.presenter.startedSubjects.count == 1)

        harness.controller.endUnowned(.recording)
        await harness.controller.settle()

        #expect(harness.presenter.endUnownedKinds.isEmpty)
        #expect(
            harness.presenter.activeSubject
                == .recording(sessionID: LiveActivityHarness.sessionID)
        )
    }

    /// The hiker's switch decides whether the app may *put* a panel on the
    /// Lock Screen. It has nothing to say about removing one that is already
    /// there — and a hiker who turned the feature off mid-hike is the person
    /// most entitled to have the leftover removed.
    ///
    /// Goes red if `guard isEnabled else { return }` is inserted at the top of
    /// `HikeLiveActivityController.endUnowned(_:)`. Named as an insertion
    /// rather than a deletion because what it pins is a guard deliberately
    /// *not* written; the doc comment on `endUnowned` argues the same point,
    /// and this is what stops the two drifting apart.
    @Test("the sweep ignores the hiker's switch")
    func sweepIgnoresTheSwitch() async {
        let harness = LiveActivityHarness.harness(liveActivities: false)
        harness.presenter.simulatePreviousLaunch(
            .recording(sessionID: LiveActivityHarness.sessionID)
        )

        harness.controller.endUnowned(.recording)
        await harness.controller.settle()

        #expect(harness.presenter.endUnownedKinds == [.recording])
    }

    /// The system switch is the other half of the same argument, and reaches
    /// `isEnabled` by a different route.
    ///
    /// Goes red under the same insertion as ``sweepIgnoresTheSwitch()``.
    @Test("the sweep ignores the system switch")
    func sweepIgnoresTheSystemSwitch() async {
        let harness = LiveActivityHarness.harness()
        harness.presenter.areActivitiesEnabled = false
        harness.presenter.simulatePreviousLaunch(
            .recording(sessionID: LiveActivityHarness.sessionID)
        )

        harness.controller.endUnowned(.recording)
        await harness.controller.settle()

        #expect(harness.presenter.endUnownedKinds == [.recording])
    }

    /// A second sweep after the first has landed is refused, because the first
    /// cleared the subject. Cheap, but it is what makes the sweep safe to call
    /// unconditionally from every ending path in the recorder — including
    /// `fail(_:endLocationUpdates:)`, which fires on every storage failure.
    ///
    /// Goes red if `guard kind.matches(presenter.activeSubject) else { return }`
    /// is deleted from `HikeLiveActivityController.endUnowned(_:)`.
    @Test("sweeping twice calls the framework once")
    func sweepingTwiceCallsTheFrameworkOnce() async {
        let harness = LiveActivityHarness.harness()
        harness.presenter.simulatePreviousLaunch(
            .recording(sessionID: LiveActivityHarness.sessionID)
        )

        harness.controller.endUnowned(.recording)
        await harness.controller.settle()
        harness.controller.endUnowned(.recording)
        await harness.controller.settle()

        #expect(harness.presenter.endUnownedKinds == [.recording])
    }

    /// The precedence rule stated as a prohibition: a sweep must never take
    /// down a panel that a *different*, still-valid subject legitimately owns.
    /// Here the hiker is following a trail and something concludes there is
    /// no recording — which is what `fail(_:endLocationUpdates:)` does on
    /// every storage failure, whether or not a recording ever existed.
    ///
    /// Goes red if the targeting is dropped and the sweep is made
    /// unconditional — `presenter.endAll()`-shaped, "end anything running that
    /// this process does not own" — which was the other design considered.
    /// Both expectations fail under it: the follow loses the screen and this
    /// process loses the `current` that carries its throttle clocks and its
    /// thirty-minute stale date.
    @Test("sweeping a recording leaves a follow this process presents alone")
    func sweepDoesNotDisturbAPresentedFollow() async {
        let harness = LiveActivityHarness.harness()
        harness.controller.update(LiveActivityHarness.followingRequest())
        await harness.controller.settle()

        harness.controller.endUnowned(.recording)
        await harness.controller.settle()

        #expect(
            harness.controller.activeSubject
                == .following(hikeID: LiveActivityHarness.hikeID)
        )
        #expect(harness.presenter.endCount == 0)
        #expect(harness.presenter.endUnownedKinds.isEmpty)
    }

    /// `matches` is the whole of the targeting, and `nil` is the case the
    /// first guard depends on being `false`.
    @Test("a kind matches nothing when there is no subject")
    func kindMatchesNoSubject() {
        #expect(HikeActivityKind.recording.matches(nil) == false)
        #expect(HikeActivityKind.following.matches(nil) == false)
        #expect(
            HikeActivityKind.recording
                .matches(.recording(sessionID: LiveActivityHarness.sessionID))
        )
        #expect(
            HikeActivityKind.following
                .matches(.following(hikeID: LiveActivityHarness.hikeID))
        )
        #expect(
            HikeActivityKind.recording
                .matches(.following(hikeID: LiveActivityHarness.hikeID)) == false
        )
        #expect(
            HikeActivityKind.following
                .matches(.recording(sessionID: LiveActivityHarness.sessionID)) == false
        )
    }
}
