//
//  HikeRecorderTests+ResumeRefusal.swift
//  OpenHikesTests
//
//  A Resume tapped on the Lock Screen that Core Location refuses (#1606).
//
//  The prompt that would grant precise location cannot be shown from the
//  background, so the resume is refused, and the panel is the only place
//  the hiker can be told why. The refusal used to fail the recording in a
//  way that took the panel down before the intent could draw on it. Now the
//  panel stays, paused, and says why; the recording screen still says why
//  too, and dismissing that returns the walk to paused for a Resume that
//  works. A failed recording still never looks like it is running, and the
//  refusal goes with its panel.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesShared
import SwiftData
import Testing

extension HikeRecorderTests {
    /// Where the refused walk takes its fix. Named because `no_magic_numbers`
    /// skips a `@Test` body and this is a helper.
    private static let refusedWalkLatitude = 47.63

    private func refusalHarness() -> (
        controller: HikeLiveActivityController,
        presenter: StubHikeActivityPresenter
    ) {
        let presenter = StubHikeActivityPresenter()
        let defaults = UserDefaults(suiteName: "recorder-resume-refusal-\(UUID().uuidString)") ?? .standard
        defaults.set(true, forKey: SettingsKey.liveActivitiesEnabled)
        return (HikeLiveActivityController(presenter: presenter, defaults: defaults, clock: clock.read), presenter)
    }

    /// A recording with its panel up, paused, and a Lock Screen Resume
    /// refused for precise location, past the flip floor the pause started.
    private func refusedLockScreenResume(
        on recorder: HikeRecorder,
        _ harness: (controller: HikeLiveActivityController, presenter: StubHikeActivityPresenter)
    ) async -> HikeActivityControlOutcome {
        await recorder.start()
        source.deliver(fix(latitude: Self.refusedWalkLatitude))
        await harness.controller.settle()
        recorder.pause()
        await harness.controller.settle()
        source.hasFullAccuracy = false
        clock.advance(by: HikeLiveActivityController.minimumFlipInterval)
        let coordinator = HikeIntentCoordinator(
            recorder: recorder,
            container: container,
            calendar: Calendar(identifier: .gregorian),
            clock: clock.read
        )
        let outcome = await coordinator.performHikeActivityControl(.resume)
        await harness.controller.settle()
        return outcome
    }

    @Test("a Lock Screen Resume refused for precise location keeps the paused panel up and says why")
    func refusedResumeIsSaidOnThePanel() async {
        let harness = refusalHarness()
        let recorder = makeRecorder(liveActivityController: harness.controller)

        let outcome = await refusedLockScreenResume(on: recorder, harness)

        #expect(outcome == .refused(.needsPreciseLocation))
        #expect(harness.presenter.endCount == 0, "the panel stays up to say why")
        let shown = harness.presenter.updatedStates.last
        #expect(shown?.controlRefusal == .needsPreciseLocation)
        #expect(shown?.runState == .paused, "a walk that cannot resume is paused, never running")
        #expect(recorder.phase == .failed(.preciseLocationRequired), "and the recording screen says why too")
    }

    /// Put right in the app: the failure dismissed, precision granted, and
    /// Resume. The run state moving is what clears the refusal.
    @Test("put right in the app, the walk resumes and the panel stops saying it could not")
    func refusedResumeIsPutRight() async {
        let harness = refusalHarness()
        let recorder = makeRecorder(liveActivityController: harness.controller)
        _ = await refusedLockScreenResume(on: recorder, harness)

        recorder.dismissFailure()
        #expect(recorder.phase == .paused)
        source.hasFullAccuracy = true
        clock.advance(by: HikeLiveActivityController.minimumFlipInterval)
        await recorder.resume()
        await harness.controller.settle()

        #expect(recorder.phase == .recording)
        #expect(harness.presenter.updatedStates.last?.runState == .running)
        #expect(harness.presenter.updatedStates.last?.controlRefusal == nil)
    }

    /// The refusal belongs to the walk it was said about: discarded, its
    /// panel goes, and the next walk's panel says nothing about a tap.
    @Test("discarded after the refusal, the panel goes, and the next walk's says nothing of it")
    func refusalGoesWithItsWalk() async {
        let harness = refusalHarness()
        let recorder = makeRecorder(liveActivityController: harness.controller)
        _ = await refusedLockScreenResume(on: recorder, harness)

        await recorder.discard()
        await harness.controller.settle()
        #expect(harness.presenter.endCount == 1)

        source.hasFullAccuracy = true
        await recorder.start()
        source.deliver(fix(latitude: 47.64))
        await harness.controller.settle()

        #expect(harness.presenter.startedSubjects.count == 2)
        #expect(harness.presenter.startedStates.last?.controlRefusal == nil)
    }
}
