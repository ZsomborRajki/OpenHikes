//
//  LiveActivityPreferenceTests.swift
//  OpenHikesTests
//
//  "Hike Live Activity preference reconciliation", split out of
//  OrphanedActivityTests.swift so that a file declares one @Suite. That
//  file's header still holds the context the two share.
//

import Foundation
@testable import OpenHikes
import OpenHikesShared
import Testing
import UIKit

/// Turning the feature off, against a panel this process does not own.
///
/// Split from the suite above because the trigger is the subject rather than
/// the sweep: `endAll()` had exactly one caller — `update(_:)`'s disabled
/// branch — and nothing in the app observed
/// `SettingsKey.liveActivitiesEnabled` at all. Reading the switch on the next
/// call is enough while a walk is running, because a walk produces fixes. An
/// orphaned panel produces nothing, so `update(_:)` was never called and the
/// switch was unreachable: a hiker relaunching to a stale panel and going
/// straight to Settings to turn Live Activities off was ignored until the
/// panel's own ten-minute stale date expired.
@Suite("Hike Live Activity preference reconciliation")
@MainActor
struct LiveActivityPreferenceTests {
    /// The headline case, and the one with no other way in: no walk, no fixes,
    /// nothing that would ever call `update(_:)`.
    ///
    /// Goes red if `observePreferences()` is deleted from
    /// `HikeLiveActivityController.init` — nothing else notices the write —
    /// and equally if the `for kind in HikeActivityKind.allCases` loop is
    /// deleted from `endAll(dismissAfter:)`, since `current` is `nil` here and
    /// the `finish` branch alone does nothing.
    @Test("turning the app's switch off takes down an orphaned recording")
    func switchOffTakesDownAnOrphanedRecording() async {
        let harness = LiveActivityHarness.harness()
        harness.presenter.simulatePreviousLaunch(
            .recording(sessionID: LiveActivityHarness.sessionID)
        )

        harness.defaults.set(false, forKey: SettingsKey.liveActivitiesEnabled)
        await harness.controller.settle()

        #expect(harness.presenter.endUnownedKinds == [.recording])
        #expect(harness.presenter.activeSubject == nil)
    }

    /// The other kind, which is where this deliberately parts company with the
    /// discard sweep in `HikeRecorder.endRecordingActivity(_:)`. That one is
    /// `.recording`-only, because a followed trail left by a previous launch
    /// is still a walk the tracker adopts back. This one is unconditional in
    /// kind, because the hiker has said they want none of it.
    ///
    /// Goes red if `endAll(dismissAfter:)` sweeps `.recording` only — the
    /// "make the two consistent" change a future reader is most likely to
    /// reach for.
    @Test("turning the app's switch off takes down an orphaned follow")
    func switchOffTakesDownAnOrphanedFollow() async {
        let harness = LiveActivityHarness.harness()
        harness.presenter.simulatePreviousLaunch(
            .following(hikeID: LiveActivityHarness.hikeID)
        )

        harness.defaults.set(false, forKey: SettingsKey.liveActivitiesEnabled)
        await harness.controller.settle()

        #expect(harness.presenter.endUnownedKinds == [.following])
        #expect(harness.presenter.activeSubject == nil)
    }

    /// The ordinary case. `UserDefaults.didChangeNotification` fires for every
    /// key in the suite and for same-value rewrites, so this path runs far
    /// more often than the switch changes and must cost nothing when there is
    /// nothing on screen.
    ///
    /// Goes red if `guard kind.matches(presenter.activeSubject) else { return }`
    /// is deleted from inside `endUnowned(_:)`'s enqueued work.
    @Test("turning the switch off with nothing running calls nothing")
    func switchOffWithNothingRunningCallsNothing() async {
        let harness = LiveActivityHarness.harness()

        harness.defaults.set(false, forKey: SettingsKey.liveActivitiesEnabled)
        await harness.controller.settle()

        #expect(harness.presenter.calls.isEmpty)
    }

    /// A walk this process *is* presenting comes down on the write itself,
    /// without waiting for another fix. The pre-existing test for this drives
    /// a second `update(_:)` afterwards, which hid the fact that the write
    /// alone did nothing.
    ///
    /// Goes red if `observePreferences()` is deleted from
    /// `HikeLiveActivityController.init`.
    @Test("turning the switch off ends a presented walk with no further fix")
    func switchOffEndsAPresentedWalkWithoutAnotherFix() async {
        let harness = LiveActivityHarness.harness()
        harness.controller.update(LiveActivityHarness.recordingRequest())
        await harness.controller.settle()
        #expect(harness.controller.activeSubject != nil)

        harness.defaults.set(false, forKey: SettingsKey.liveActivitiesEnabled)
        await harness.controller.settle()

        #expect(harness.presenter.endCount == 1)
        #expect(harness.controller.activeSubject == nil)
        #expect(harness.presenter.activeSubject == nil)
    }

    /// The guard that makes the notification safe to subscribe to. It fires
    /// for *every* key in the suite, so without this a hiker changing their
    /// units mid-hike would lose the Lock Screen panel.
    ///
    /// Goes red if `guard !isEnabled else { return }` is deleted from
    /// `reconcileWithPreferences()`.
    @Test("an unrelated defaults write leaves a running walk alone")
    func unrelatedDefaultsWriteLeavesTheWalkAlone() async {
        let harness = LiveActivityHarness.harness()
        harness.controller.update(LiveActivityHarness.recordingRequest())
        await harness.controller.settle()

        harness.defaults.set("metric", forKey: "settings.unitsForThisTestOnly")
        await harness.controller.settle()

        #expect(harness.presenter.endCount == 0)
        #expect(
            harness.controller.activeSubject
                == .recording(sessionID: LiveActivityHarness.sessionID)
        )
    }

    /// The system's per-app switch, which is not a default and changes only in
    /// iOS Settings — so returning to the foreground is the only moment the
    /// app can re-ask. Driven through `reconcileWithPreferences()` directly,
    /// which is the policy; ``theAppBecomingActiveTakesDownAnOrphan()`` is the
    /// registration that reaches it.
    ///
    /// Goes red if `endAll()` is deleted from `reconcileWithPreferences()`.
    @Test("the system's switch going off takes down an orphan on return")
    func systemSwitchOffTakesDownAnOrphan() async {
        let harness = LiveActivityHarness.harness()
        harness.presenter.simulatePreviousLaunch(
            .recording(sessionID: LiveActivityHarness.sessionID)
        )
        harness.presenter.areActivitiesEnabled = false

        harness.controller.reconcileWithPreferences()
        await harness.controller.settle()

        #expect(harness.presenter.endUnownedKinds == [.recording])
        #expect(harness.presenter.activeSubject == nil)
    }

    /// The other half of that, and the half the policy above cannot see: the
    /// registration itself. `observePreferences` asks for
    /// `UIApplication.DidBecomeActiveMessage`, and a wrong message type, a
    /// dropped token or a legacy post that no longer bridges into a typed
    /// observer would all leave every test above green while the hiker's
    /// stale panel stayed on their Lock Screen forever.
    ///
    /// Posted on the controller's own centre rather than the process-wide one,
    /// which is what makes this testable at all: the test host is a running
    /// app, and posting `UIApplication.didBecomeActiveNotification` on
    /// `.default` would reach into every other controller alive in it.
    ///
    /// Goes red if `observePreferences()`'s lifecycle observer is deleted, if
    /// its token is dropped instead of appended to `lifecycleObservers`, or if
    /// it is registered for a different message.
    @Test("the app becoming active is what re-asks the system's switch")
    func theAppBecomingActiveTakesDownAnOrphan() async {
        let harness = LiveActivityHarness.harness()
        harness.presenter.simulatePreviousLaunch(
            .recording(sessionID: LiveActivityHarness.sessionID)
        )
        harness.presenter.areActivitiesEnabled = false

        harness.postDidBecomeActive()
        await harness.controller.settle()

        #expect(harness.presenter.endUnownedKinds == [.recording])
        #expect(harness.presenter.activeSubject == nil)
    }

    /// Teardown, which is the failure the app-hosted bundles would feel first:
    /// they build hundreds of these controllers, and an observer that outlived
    /// its controller would either keep the controller alive with it or go on
    /// reconciling against a stub some earlier test has finished with.
    ///
    /// Two assertions rather than one, because they fail for different
    /// reasons. That the controller is gone at all is the `[weak self]` in the
    /// handler — a strong capture makes the centre the controller's owner. That
    /// nothing was reconciled afterwards is the token's own lifetime, pinned
    /// against Foundation in `LifecycleObservationTokenTests`.
    @Test("a released controller is not kept alive by its own observer")
    func aReleasedControllerObservesNothing() {
        let presenter = StubHikeActivityPresenter()
        let center = NotificationCenter()
        weak var released: HikeLiveActivityController?

        do {
            let controller = HikeLiveActivityController(
                presenter: presenter,
                defaults: LiveActivityHarness.defaults(),
                lifecycleCenter: center
            )
            released = controller
            withExtendedLifetime(controller) { /* released at the end of this scope */ }
        }

        #expect(released == nil, "the notification centre must not own the controller")

        presenter.simulatePreviousLaunch(
            .recording(sessionID: LiveActivityHarness.sessionID)
        )
        presenter.areActivitiesEnabled = false
        center.post(name: UIApplication.didBecomeActiveNotification, object: nil)

        #expect(presenter.endUnownedKinds.isEmpty)
        #expect(presenter.activeSubject != nil, "nothing is left to take the orphan down")
    }

    /// Reconciling while both switches say yes must leave everything exactly
    /// where it is, orphan included: an orphaned recording is what a resumed
    /// walk is about to adopt.
    ///
    /// Goes red if `guard !isEnabled else { return }` is deleted from
    /// `reconcileWithPreferences()`.
    @Test("reconciling while enabled leaves an orphan for the walk to adopt")
    func reconcilingWhileEnabledLeavesTheOrphan() async {
        let harness = LiveActivityHarness.harness()
        harness.presenter.simulatePreviousLaunch(
            .recording(sessionID: LiveActivityHarness.sessionID)
        )

        harness.controller.reconcileWithPreferences()
        await harness.controller.settle()

        #expect(harness.presenter.calls.isEmpty)
        #expect(
            harness.presenter.activeSubject
                == .recording(sessionID: LiveActivityHarness.sessionID)
        )
    }
}
