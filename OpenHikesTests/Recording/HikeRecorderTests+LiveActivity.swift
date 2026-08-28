//
//  HikeRecorderTests+LiveActivity.swift
//  OpenHikesTests
//
//  That a recording reaches the Lock Screen, and leaves it.
//
//  The policy itself — precedence, throttling, what an update is worth — is
//  `HikeLiveActivityControllerTests`. What is asserted here is the wiring: that
//  the recorder publishes at all, that it publishes the same figures the
//  widget gets, and that every way a session can end takes the activity with
//  it — including the ways that end badly. The last one is the whole risk of
//  the feature: an activity that outlives its recording sits on the Lock
//  Screen reporting a walk that is over, and nothing in the app would ever
//  take it down.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesShared
import SwiftData
import Testing

extension HikeRecorderTests {
    /// The two fixes the failure fixture below walks between. Named rather
    /// than inline because `no_magic_numbers` skips a `@Test` body and this is
    /// a helper.
    private static let firstFixLatitude = 47.63
    private static let secondFixLatitude = 47.6302

    private func liveActivityHarness() -> (
        controller: HikeLiveActivityController,
        presenter: StubHikeActivityPresenter
    ) {
        let presenter = StubHikeActivityPresenter()
        let defaults = UserDefaults(
            suiteName: "recorder-live-activity-\(UUID().uuidString)"
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

    @Test("the first accepted fix puts the recording on the Lock Screen")
    func recordingStartsAnActivity() async throws {
        let harness = liveActivityHarness()
        let recorder = makeRecorder(liveActivityController: harness.controller)
        await recorder.start()
        source.deliver(fix(latitude: 47.63))
        await harness.controller.settle()

        let sessionID = try #require(recorder.sessionID)
        #expect(
            harness.presenter.startedSubjects == [.recording(sessionID: sessionID)]
        )
    }

    /// The point of routing both surfaces through ``SharedRecordingSnapshot``:
    /// the number on the Lock Screen is the recorder's own, not a second
    /// derivation of it.
    ///
    /// Read off an *update* rather than the start, because the activity
    /// deliberately appears the moment recording begins — before there is a
    /// fix to report — so the walker sees it come up when they press Start
    /// rather than whenever GPS first agrees.
    @Test("the activity carries the recorder's own figures")
    func activityCarriesRecorderFigures() async throws {
        let harness = liveActivityHarness()
        let recorder = makeRecorder(liveActivityController: harness.controller)
        await recorder.start()
        source.deliver(fix(latitude: 47.63))
        await harness.controller.settle()
        #expect(harness.presenter.startedStates.count == 1)

        clock.advance(by: HikeLiveActivityController.minimumUpdateInterval)
        source.deliver(fix(latitude: 47.6305))
        await harness.controller.settle()

        let latest = try #require(harness.presenter.updatedStates.last)
        #expect(latest.distanceMeters == recorder.stats.distanceMeters)
        #expect(latest.pointCount == recorder.stats.pointCount)
        #expect(latest.runState == .running)
        #expect(recorder.stats.pointCount == 2)
    }

    /// A paused recording is still a recording — the activity stays, and says
    /// so. Ending it would lose the walker the thing they came back to.
    @Test("pausing updates the activity rather than ending it")
    func pausingKeepsTheActivity() async {
        let harness = liveActivityHarness()
        let recorder = makeRecorder(liveActivityController: harness.controller)
        await recorder.start()
        source.deliver(fix(latitude: 47.63))
        await harness.controller.settle()

        recorder.pause()
        await harness.controller.settle()
        #expect(harness.presenter.endCount == 0)
        #expect(harness.presenter.updatedStates.last?.runState == .paused)
    }

    /// The discard path. No final panel and no lingering: there is no hike to
    /// show, and one left on screen would say a walk was saved that wasn't.
    @Test("discarding a recording removes the activity at once")
    func discardingRemovesTheActivity() async {
        let harness = liveActivityHarness()
        let recorder = makeRecorder(liveActivityController: harness.controller)
        await recorder.start()
        source.deliver(fix(latitude: 47.63))
        await harness.controller.settle()

        await recorder.discard()
        await harness.controller.settle()
        #expect(harness.controller.activeSubject == nil)
        #expect(
            harness.presenter.calls.last == .end(finalState: nil, dismissAfter: nil)
        )
    }

    /// A recorder with its activity on screen, stopped straight into a
    /// storage failure — the walker's "tap Stop, hit an error" path.
    ///
    /// `failedSaveNumbers: [2]` because the first save is the draft
    /// `ensureRecordingHike` writes at activation and the second is `persist`.
    private func recorderAfterAFailedStop(
        controller: HikeLiveActivityController
    ) async throws -> HikeRecorder {
        let saver = ScriptedModelContextSaver(failedSaveNumbers: [2])
        let recorder = makeRecorder(
            liveActivityController: controller,
            saveModelContext: saver.save
        )
        await recorder.start()
        source.deliver(fix(latitude: Self.firstFixLatitude))
        clock.advance(by: 10)
        source.deliver(fix(latitude: Self.secondFixLatitude))
        await controller.settle()
        let sessionID = try #require(recorder.sessionID)
        #expect(
            controller.activeSubject == .recording(sessionID: sessionID),
            "the recording has to reach the Lock Screen before losing it can be asserted"
        )

        do {
            _ = try await recorder.stop()
            Issue.record("the injected persistence failure was ignored")
        } catch let failure as RecordingFailure {
            guard case .save = failure else {
                Issue.record("the stop returned the wrong failure")
                throw failure
            }
        }
        await controller.settle()
        guard case .failed = recorder.phase else {
            Issue.record("the injected failure did not leave the recorder failed")
            throw RecordingFailure.save("the recorder did not fail")
        }
        return recorder
    }

    /// The failure path, which nothing used to take down. Stopping a
    /// recording turns the sensors off and the recorder publishes nothing
    /// further, so the last state the panel holds says
    /// `isCapturingFixes: false` — which it draws as *Paused*. Left there it
    /// spends the whole ten-minute stale window telling a walker whose hike is
    /// over that it is waiting for them.
    ///
    /// Removed outright rather than finished off with the walk's totals: no
    /// `Hike` was written, and a lingering final panel claims one that was.
    /// The walker who retries the save is looking at the app.
    @Test("a failed save takes the recording off the Lock Screen")
    func failedSaveEndsTheActivity() async throws {
        let harness = liveActivityHarness()
        let recorder = try await recorderAfterAFailedStop(
            controller: harness.controller
        )

        #expect(harness.controller.activeSubject == nil)
        #expect(
            harness.presenter.calls.last == .end(finalState: nil, dismissAfter: nil)
        )
        #expect(recorder.canRetrySave, "the save is still retryable; the panel was never the retry")
    }

    /// And it stays off. A failed recorder is still `isActive` — that is how
    /// the walker gets back to it — so pocketing the phone publishes one more
    /// snapshot, which the widget genuinely wants. Letting that reach the
    /// controller would find nothing running and *start* a second activity for
    /// the recording that just failed: the same "Paused" claim, arriving by a
    /// slightly longer route.
    @Test("a scene change after a failed save starts no replacement activity")
    func sceneChangeAfterAFailedSaveStartsNoSecondActivity() async throws {
        let harness = liveActivityHarness()
        let recorder = try await recorderAfterAFailedStop(
            controller: harness.controller
        )

        recorder.sceneWillResignActive()
        recorder.sceneDidBecomeActive()
        await recorder.journalQueue.drain()
        await harness.controller.settle()

        #expect(harness.controller.activeSubject == nil)
        #expect(
            harness.presenter.startedSubjects.count == 1,
            "the one this recording began with, and no replacement for it"
        )
    }

    /// A recorder built without a controller has to behave exactly as it did
    /// before the feature existed — which is what makes the dependency
    /// genuinely optional rather than merely nullable.
    @Test("a recorder with no controller records normally")
    func recordingWithoutAControllerIsUnaffected() async {
        let recorder = makeRecorder()
        await recorder.start()
        source.deliver(fix(latitude: 47.63))
        #expect(recorder.stats.pointCount == 1)
        #expect(recorder.phase == .recording)
    }
}
