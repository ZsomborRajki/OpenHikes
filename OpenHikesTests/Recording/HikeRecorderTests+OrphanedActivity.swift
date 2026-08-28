//
//  HikeRecorderTests+OrphanedActivity.swift
//  OpenHikesTests
//
//  The launch paths that end a recording they never started.
//
//  `HikeRecorderTests+LiveActivity` covers the ways a session this process is
//  running can end. These are the ways a session it is *not* running ends: the
//  app was killed mid-hike, the Live Activity outlived it, and the next launch
//  concludes there is no recording after all — the journal has gone, or the
//  walk cannot start at all.
//
//  Before `endUnowned(_:)`, `endRecordingActivity(_:)` opened by asking the
//  controller what *this process* was presenting, got `nil`, and returned. The
//  panel then sat out its ten-minute stale window telling a walker with no
//  recording that their walk was live.
//
//  The recovery-then-discard path is here too, asserting the opposite: it
//  republishes on the way through and so ends up owning the panel, which is
//  why it must *not* be diverted into the sweep.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesShared
import SwiftData
import Testing

extension HikeRecorderTests {
    /// A controller wired to a stub, plus a panel already on the Lock Screen
    /// that this process did not put there. `simulatePreviousLaunch` records
    /// no call, so anything the assertions see is something the recorder did.
    private func orphanHarness(
        leftBehind subject: HikeActivityAttributes.Subject?
    ) -> (controller: HikeLiveActivityController, presenter: StubHikeActivityPresenter) {
        let presenter = StubHikeActivityPresenter()
        if let subject { presenter.simulatePreviousLaunch(subject) }
        let defaults = UserDefaults(
            suiteName: "recorder-orphan-activity-\(UUID().uuidString)"
        ) ?? .standard
        defaults.set(true, forKey: SettingsKey.liveActivitiesEnabled)
        return (
            HikeLiveActivityController(
                presenter: presenter,
                defaults: defaults,
                clock: clock.read
            ),
            presenter
        )
    }

    /// `HikeRecorder+Lifecycle`'s missing-session branch. The walk was killed,
    /// its journal is gone, and the only thing left of it is the panel.
    ///
    /// Goes red if `liveActivityController.endUnowned(.recording)` is deleted
    /// from `endRecordingActivity(_:)` in `HikeRecorder+Helpers`, or if that
    /// method's opening guard is put back the way it was — one combined
    /// `guard let liveActivityController, let subject = …, subject.isRecording
    /// else { return }`.
    @Test("a launch that finds no session takes down the previous launch's panel")
    func missingSessionEndsTheOrphanedActivity() async {
        let harness = orphanHarness(
            leftBehind: .recording(sessionID: UUID())
        )
        let recorder = makeRecorder(liveActivityController: harness.controller)

        await recorder.recoverOpenSession()
        await harness.controller.settle()

        #expect(recorder.phase == .idle)
        #expect(harness.presenter.endUnownedKinds == [.recording])
        #expect(harness.presenter.activeSubject == nil)
    }

    /// The same launch with nothing left on the Lock Screen, which is the
    /// ordinary case: the recorder still calls through, and the controller
    /// refuses. Without this, a sweep could be made unconditional and every
    /// launch would spend a framework call on nothing.
    ///
    /// Goes red if `guard kind.matches(presenter.activeSubject) else { return }`
    /// is deleted from `HikeLiveActivityController.endUnowned(_:)`.
    @Test("a launch that finds no session and no panel does nothing")
    func missingSessionWithNoPanelDoesNothing() async {
        let harness = orphanHarness(leftBehind: nil)
        let recorder = makeRecorder(liveActivityController: harness.controller)

        await recorder.recoverOpenSession()
        await harness.controller.settle()

        #expect(recorder.phase == .idle)
        #expect(harness.presenter.calls.isEmpty)
    }

    /// Precedence on the launch path. The walker was following a trail when
    /// the app died; the trail is still there and the tracker adopts the panel
    /// back on the next matched fix. A launch discovering it has no recording
    /// must leave it alone.
    ///
    /// Goes red if the sweep is made unconditional, or if
    /// `HikeActivityKind.matches(_:)`'s `case .recording` stops asking
    /// `subject.isRecording`.
    @Test("a launch that finds no session leaves a followed trail's panel up")
    func missingSessionLeavesAFollowAlone() async {
        let harness = orphanHarness(
            leftBehind: .following(hikeID: UUID())
        )
        let recorder = makeRecorder(liveActivityController: harness.controller)

        await recorder.recoverOpenSession()
        await harness.controller.settle()

        #expect(harness.presenter.calls.isEmpty)
        #expect(harness.presenter.activeSubject?.isRecording == false)
    }

    /// The recovery decision the walker actually makes, and the one place the
    /// original report of this bug is wrong: by the time Discard is tapped,
    /// this process *does* own the panel. `finishRecovery` publishes a shared
    /// snapshot on both of its branches, that publish reaches
    /// `liveActivityController.update`, and with `current` still `nil` the
    /// controller starts — which in the real presenter adopts the previous
    /// launch's activity, since the recovered session ID is the one it was
    /// requested with. So Discard takes the ordinary `end(subject:)` path and
    /// always did.
    ///
    /// Kept because relaxing `endRecordingActivity`'s guard is exactly the
    /// change that could have diverted this case into the sweep, which cannot
    /// leave a final panel and would have been a silent regression.
    ///
    /// Goes red if `endRecordingActivity(_:)` calls
    /// `liveActivityController.endUnowned(.recording)` unconditionally rather
    /// than only in the branch where nothing of this process's is running.
    @Test("discarding a recovered recording ends the panel it adopted")
    func discardingARecoveredRecordingEndsTheAdoptedActivity() async throws {
        let recoveredSessionID = UUID()
        let journal = TrackJournal(directory: directory, clock: clock.read)
        try await journal.start(sessionID: recoveredSessionID, startedAt: clock.now)
        try await journal.append(
            RecordingPoint(
                latitude: 47.63,
                longitude: 12.86,
                timestamp: clock.now,
                horizontalAccuracy: 8
            )
        )
        try await journal.pause(at: clock.now)
        try await journal.close()

        let harness = orphanHarness(
            leftBehind: .recording(sessionID: recoveredSessionID)
        )
        let recorder = makeRecorder(liveActivityController: harness.controller)
        await recorder.recoverOpenSession()
        await harness.controller.settle()
        guard case .needsDecision = recorder.recoveryState else {
            Issue.record("the recovered pause should have been offered to the walker")
            return
        }
        #expect(
            harness.controller.activeSubject == .recording(sessionID: recoveredSessionID),
            "recovering republishes, which is what reclaims the previous launch's panel"
        )

        await recorder.discard()
        await harness.controller.settle()

        #expect(harness.presenter.calls.last == .end(finalState: nil, dismissAfter: nil))
        #expect(harness.presenter.endUnownedKinds.isEmpty)
        #expect(harness.presenter.activeSubject == nil)
        #expect(try context.fetch(FetchDescriptor<Hike>()).isEmpty)
    }

    /// The third orphan path, and the one that needs no journal at all: a
    /// walker whose app was killed mid-hike revokes location in Settings and
    /// then taps Record. `start()` fails on `.locationDenied` before a session
    /// exists, and `fail(_:endLocationUpdates:)` ends with
    /// `endRecordingActivity(.abandoned)` against a controller holding nothing.
    ///
    /// Goes red if `liveActivityController.endUnowned(.recording)` is deleted
    /// from `endRecordingActivity(_:)` in `HikeRecorder+Helpers`.
    @Test("a start that fails before any session takes the orphaned panel down")
    func failingBeforeASessionEndsTheOrphanedActivity() async {
        let harness = orphanHarness(
            leftBehind: .recording(sessionID: UUID())
        )
        let recorder = makeRecorder(liveActivityController: harness.controller)
        source.authorization = .denied

        await recorder.start()
        await harness.controller.settle()

        #expect(recorder.phase == .failed(.locationDenied))
        #expect(harness.presenter.endUnownedKinds == [.recording])
        #expect(harness.presenter.activeSubject == nil)
    }

    /// The resume branch, which was already correct and must stay so. Resuming
    /// republishes, that publish reaches `update`, `current` is `nil` so the
    /// controller starts — and the real presenter adopts the running activity
    /// there rather than requesting a second one. Nothing here may sweep, and
    /// the recovered session ID is what proves the panel was reclaimed rather
    /// than replaced.
    ///
    /// Goes red if the sweep is moved onto the launch path itself — an
    /// unconditional reconcile at the top of `recoverOpenSession` was the other
    /// design considered, and it would take down exactly the panel this branch
    /// is about to reclaim.
    @Test("resuming a recovered recording reclaims the panel rather than sweeping it")
    func resumingARecoveredRecordingSweepsNothing() async throws {
        let recoveredSessionID = UUID()
        let journal = TrackJournal(directory: directory, clock: clock.read)
        try await journal.start(sessionID: recoveredSessionID, startedAt: clock.now)
        try await journal.append(
            RecordingPoint(
                latitude: 47.63,
                longitude: 12.86,
                timestamp: clock.now,
                horizontalAccuracy: 8
            )
        )
        try await journal.close()

        let harness = orphanHarness(
            leftBehind: .recording(sessionID: recoveredSessionID)
        )
        let recorder = makeRecorder(liveActivityController: harness.controller)
        await recorder.recoverOpenSession()
        await harness.controller.settle()

        #expect(recorder.phase == .recording)
        #expect(harness.presenter.endUnownedKinds.isEmpty)
        #expect(harness.presenter.endCount == 0)
        #expect(
            harness.presenter.startedSubjects == [.recording(sessionID: recoveredSessionID)]
        )
        #expect(
            harness.presenter.activeSubject == .recording(sessionID: recoveredSessionID)
        )
    }
}
