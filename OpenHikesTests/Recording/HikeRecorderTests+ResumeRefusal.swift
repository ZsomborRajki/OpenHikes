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
//  The panel it leaves up still offers Resume and Stop, so both are held
//  here too: a Resume tapped again asks again, and works once the hiker has
//  put it right in Settings, and a Stop asks Stop's question of the paused
//  walk. See ``HikeRecorder/reopenRefusedResume()``.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesShared
import SwiftData
import Testing

extension HikeRecorderTests {
    private typealias RefusalHarness = (
        controller: HikeLiveActivityController,
        presenter: StubHikeActivityPresenter
    )

    /// Where the refused walk takes its two fixes, and how far apart in
    /// time: a line, so that Stop asks for a name. Named because
    /// `no_magic_numbers` skips a `@Test` body and this is a helper.
    private static let refusedWalkLatitude = 47.63
    private static let refusedWalkSecondLatitude = 47.631
    private static let refusedWalkFixSpacing: TimeInterval = 60

    private func refusalHarness() -> RefusalHarness {
        let presenter = StubHikeActivityPresenter()
        let defaults = UserDefaults(suiteName: "recorder-resume-refusal-\(UUID().uuidString)") ?? .standard
        defaults.set(true, forKey: SettingsKey.liveActivitiesEnabled)
        return (HikeLiveActivityController(presenter: presenter, defaults: defaults, clock: clock.read), presenter)
    }

    private func coordinator(for recorder: HikeRecorder) -> HikeIntentCoordinator {
        HikeIntentCoordinator(
            recorder: recorder,
            container: container,
            calendar: Calendar(identifier: .gregorian),
            clock: clock.read
        )
    }

    /// A recording with a line and its panel up, paused, and a Lock Screen
    /// Resume refused for precise location `delay` after the pause: by
    /// default past the flip floor the pause started.
    private func refusedLockScreenResume(
        on recorder: HikeRecorder,
        _ harness: RefusalHarness,
        after delay: TimeInterval = HikeLiveActivityController.minimumFlipInterval
    ) async -> HikeActivityControlOutcome {
        await recorder.start()
        source.deliver(fix(latitude: Self.refusedWalkLatitude))
        clock.advance(by: Self.refusedWalkFixSpacing)
        source.deliver(fix(latitude: Self.refusedWalkSecondLatitude))
        await harness.controller.settle()
        recorder.pause()
        await harness.controller.settle()
        source.hasFullAccuracy = false
        clock.advance(by: delay)
        let outcome = await coordinator(for: recorder).performHikeActivityControl(.resume)
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

    /// The Pause before it moved the run-state clock, and the refusal used
    /// to wait on that clock — for good, because nothing publishes to a
    /// failed recording's panel to carry it later.
    @Test("a Resume refused just after the Pause is said on the panel all the same")
    func refusedResumeInsideThePauseFloorIsSaid() async {
        let harness = refusalHarness()
        let recorder = makeRecorder(liveActivityController: harness.controller)

        let outcome = await refusedLockScreenResume(on: recorder, harness, after: 1)

        #expect(outcome == .refused(.needsPreciseLocation))
        #expect(harness.presenter.updatedStates.last?.controlRefusal == .needsPreciseLocation)
        #expect(harness.presenter.updatedStates.last?.runState == .paused)
    }

    /// The panel still offers Resume. A second tap is a second ask, never
    /// "that hike isn't recording any more" over the words that say how to
    /// put it right.
    @Test("tapped again, the panel's Resume asks again and the panel still says why")
    func refusedResumeTappedAgainAsksAgain() async {
        let harness = refusalHarness()
        let recorder = makeRecorder(liveActivityController: harness.controller)
        _ = await refusedLockScreenResume(on: recorder, harness)

        clock.advance(by: HikeLiveActivityController.minimumFlipInterval)
        let again = await coordinator(for: recorder).performHikeActivityControl(.resume)
        await harness.controller.settle()

        #expect(again == .refused(.needsPreciseLocation))
        #expect(harness.presenter.endCount == 0)
        #expect(harness.presenter.updatedStates.last?.controlRefusal == .needsPreciseLocation)
        #expect(recorder.phase == .failed(.preciseLocationRequired))
    }

    /// Put right in Settings, and straight back to the Lock Screen: the
    /// panel's own Resume is enough, without opening the app.
    @Test("granted in Settings, the panel's Resume resumes the walk and the refusal goes")
    func refusedResumeIsPutRightFromThePanel() async {
        let harness = refusalHarness()
        let recorder = makeRecorder(liveActivityController: harness.controller)
        _ = await refusedLockScreenResume(on: recorder, harness)

        source.hasFullAccuracy = true
        clock.advance(by: HikeLiveActivityController.minimumFlipInterval)
        let again = await coordinator(for: recorder).performHikeActivityControl(.resume)
        await harness.controller.settle()

        #expect(again == .completed)
        #expect(recorder.phase == .recording)
        #expect(harness.presenter.updatedStates.last?.runState == .running)
        #expect(harness.presenter.updatedStates.last?.controlRefusal == nil)
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

    /// The panel's Stop opens the app and asks Stop's question, which a
    /// failed recording has no answer to.
    @Test("the panel's Stop asks the walk whose resume was refused for its name")
    func refusedResumeAnswersThePanelsStop() async {
        let harness = refusalHarness()
        let recorder = makeRecorder(liveActivityController: harness.controller)
        _ = await refusedLockScreenResume(on: recorder, harness)
        let question = RecordingStopQuestion(recorder: recorder, endings: EventFeed())

        await question.ask()

        #expect(question.isAskingName)
        #expect(recorder.phase == .paused, "asking ends nothing, and the walk is the paused one it was")
    }

    /// Siri's Stop and the watch's are the same Stop.
    @Test("Siri's Stop saves the walk whose resume was refused")
    func refusedResumeIsStoppedBySiri() async throws {
        let harness = refusalHarness()
        let recorder = makeRecorder(liveActivityController: harness.controller)
        _ = await refusedLockScreenResume(on: recorder, harness)

        let stopped = try await coordinator(for: recorder).stopRecording()

        guard case .saved = stopped else {
            Issue.record("a walk with a line should be saved, got \(stopped)")
            return
        }
        #expect(recorder.phase == .idle)
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
