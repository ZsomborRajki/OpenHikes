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
//  it. The last one is the whole risk of the feature: an activity that outlives
//  its recording sits on the Lock Screen reporting a walk that is over, and
//  nothing in the app would ever take it down.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesShared
import Testing

extension HikeRecorderTests {
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
