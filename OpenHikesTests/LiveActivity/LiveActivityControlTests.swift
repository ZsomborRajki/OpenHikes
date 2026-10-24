//
//  LiveActivityControlTests.swift
//  OpenHikesTests
//
//  The panel's own pause and resume, and the refusal it has to draw because
//  it has nowhere else to put one.
//
//  ActivityKit still cannot be exercised from a hosted unit test, so nothing
//  here presses a real button. What is asserted is everything above
//  ``HikeActivityPresenting``, which is where the behaviour lives: that a
//  refusal reaches the panel at all, that it is rate-limited as the status
//  flip it is, that it stops being shown the moment the thing the hiker
//  asked for actually happens, and that it never outlives the panel it was
//  drawn on.
//
//  The clock is driven by hand for the reason ``LiveActivityStatusFloorTests``
//  gives: a suite that waited out a ten-second floor would be measuring
//  `Task.sleep`.
//

import Foundation
@testable import OpenHikes
import OpenHikesShared
import Testing

@MainActor
@Suite("Hike Live Activity controls")
struct LiveActivityControlTests {
    private func at(_ seconds: TimeInterval) -> Date {
        LiveActivityHarness.start.addingTimeInterval(seconds)
    }

    /// The whole point of the field. A `LiveActivityIntent` has no dialog and
    /// no `continueInForeground(_:)`, so a refusal either reaches the panel or
    /// reaches nobody.
    @Test("a refusal reaches the panel")
    func aRefusalIsDrawn() async {
        let harness = LiveActivityHarness.harness()
        harness.controller.update(LiveActivityHarness.recordingRequest())
        await harness.controller.settle()

        harness.now.date = at(30)
        harness.controller.noteControlRefusal(.needsPreciseLocation)
        await harness.controller.settle()

        #expect(harness.presenter.updatedStates.last?.controlRefusal == .needsPreciseLocation)
    }

    /// It is a status flip in exactly the sense `minimumFlipInterval` exists
    /// for — the hiker just touched the panel and is looking at it — so it
    /// bypasses the twenty-second update floor and pays the ten-second one.
    @Test("a refusal bypasses the ordinary update interval")
    func aRefusalDoesNotWaitForTheUpdateFloor() async {
        let harness = LiveActivityHarness.harness()
        harness.controller.update(LiveActivityHarness.recordingRequest())
        await harness.controller.settle()
        let before = harness.presenter.updatedStates.count

        // Well inside the twenty-second update floor.
        harness.now.date = at(11)
        harness.controller.noteControlRefusal(.needsPreciseLocation)
        await harness.controller.settle()

        #expect(harness.presenter.updatedStates.count == before + 1)
    }

    /// A button can be hammered even though it cannot flap at GPS rates, and
    /// `NSSupportsLiveActivitiesFrequentUpdates` is deliberately absent.
    @Test("a second refusal inside the flip floor is not sent")
    func refusalsAreFloored() async {
        let harness = LiveActivityHarness.harness()
        harness.controller.update(LiveActivityHarness.recordingRequest())
        await harness.controller.settle()

        harness.now.date = at(30)
        harness.controller.noteControlRefusal(.needsPreciseLocation)
        await harness.controller.settle()
        let after = harness.presenter.updatedStates.count

        // Two seconds later, inside the ten-second flip floor.
        harness.now.date = at(32)
        harness.controller.noteControlRefusal(.needsPreciseLocation)
        await harness.controller.settle()

        #expect(harness.presenter.updatedStates.count == after)
    }

    /// The run state changing is the proof that what the hiker asked for has
    /// happened, so the refusal has stopped being true.
    @Test("the refusal clears when the pause actually lands")
    func aRefusalClearsOnTheNextRunStateChange() async {
        let harness = LiveActivityHarness.harness()
        harness.controller.update(LiveActivityHarness.recordingRequest())
        await harness.controller.settle()

        harness.now.date = at(30)
        harness.controller.noteControlRefusal(.needsPreciseLocation)
        await harness.controller.settle()
        #expect(harness.presenter.updatedStates.last?.controlRefusal != nil)

        harness.now.date = at(30)
        harness.controller.update(
            LiveActivityHarness.recordingRequest(runState: .paused, at: at(60))
        )
        await harness.controller.settle()

        #expect(harness.presenter.updatedStates.last?.controlRefusal == nil)
    }

    /// Until then it stays on screen: an ordinary interval update carries it
    /// rather than quietly dropping the only thing the hiker was told.
    @Test("an ordinary update carries the refusal rather than dropping it")
    func aRefusalOutlivesOneUpdate() async {
        let harness = LiveActivityHarness.harness()
        harness.controller.update(LiveActivityHarness.recordingRequest())
        await harness.controller.settle()

        harness.now.date = at(30)
        harness.controller.noteControlRefusal(.needsPreciseLocation)
        await harness.controller.settle()

        // Past the twenty-second floor the refusal push restarted, so this
        // update is really sent rather than refused and the refusal's own
        // push read back.
        harness.now.date = at(60)
        harness.controller.update(
            LiveActivityHarness.recordingRequest(distanceMeters: 2000, at: at(60))
        )
        await harness.controller.settle()

        #expect(harness.presenter.updatedStates.count == 2)
        #expect(harness.presenter.updatedStates.last?.controlRefusal == .needsPreciseLocation)
    }

    /// Nothing to draw on, nothing to say. A refusal with no activity running
    /// must not start one.
    @Test("a refusal with no panel up starts nothing")
    func aRefusalWithoutAPanelIsDropped() async {
        let harness = LiveActivityHarness.harness()

        harness.controller.noteControlRefusal(.failed)
        await harness.controller.settle()

        #expect(harness.presenter.calls.isEmpty)
    }

    /// Nor is it kept for whichever panel comes next. The recording that
    /// starts afterwards started successfully, so a refusal arriving on its
    /// first interval update would be telling the hiker about a tap that
    /// belonged to nothing on screen.
    @Test("a refusal with no panel up is not drawn on the next one")
    func aRefusalWithoutAPanelIsNotCarriedForward() async {
        let harness = LiveActivityHarness.harness()
        harness.controller.noteControlRefusal(.needsPreciseLocation)

        harness.controller.update(LiveActivityHarness.recordingRequest())
        await harness.controller.settle()

        // Past the twenty-second floor, and far enough to be worth drawing.
        harness.now.date = at(30)
        harness.controller.update(
            LiveActivityHarness.recordingRequest(distanceMeters: 2000, at: at(30))
        )
        await harness.controller.settle()

        #expect(harness.presenter.updatedStates.count == 1)
        #expect(harness.presenter.updatedStates.last?.controlRefusal == nil)
    }

    /// A refusal is about the panel it was drawn on. Once that recording has
    /// ended, the next one is a different walk with buttons nobody has
    /// pressed yet.
    @Test("a refusal does not outlive the recording it was drawn on")
    func aRefusalEndsWithItsActivity() async {
        let harness = LiveActivityHarness.harness()
        harness.controller.update(LiveActivityHarness.recordingRequest())
        await harness.controller.settle()

        harness.now.date = at(30)
        harness.controller.noteControlRefusal(.needsPreciseLocation)
        await harness.controller.settle()
        #expect(harness.presenter.updatedStates.last?.controlRefusal == .needsPreciseLocation)

        harness.controller.end(
            subject: .recording(sessionID: LiveActivityHarness.sessionID),
            finalState: LiveActivityHarness.recordingRequest(runState: .finished, at: at(30)).state,
            dismissAfter: HikeLiveActivityController.finishedDismissAfter
        )
        let next = UUID()
        harness.now.date = at(60)
        harness.controller.update(LiveActivityHarness.recordingRequest(at: at(60), session: next))
        await harness.controller.settle()

        harness.now.date = at(90)
        harness.controller.update(
            LiveActivityHarness.recordingRequest(distanceMeters: 2000, at: at(90), session: next)
        )
        await harness.controller.settle()

        #expect(harness.presenter.startedSubjects.last == .recording(sessionID: next))
        // The refusal on the first recording, then the second one's update.
        #expect(harness.presenter.updatedStates.count == 2)
        #expect(harness.presenter.updatedStates.last?.controlRefusal == nil)
    }

    /// The same for a walk that loses the screen rather than ending: a
    /// recording taking over from a follow replaces it, refusal and all.
    @Test("a refusal does not pass to the walk that replaces its panel")
    func aRefusalIsNotInheritedByAReplacement() async {
        let harness = LiveActivityHarness.harness()
        harness.controller.update(LiveActivityHarness.followingRequest())
        await harness.controller.settle()

        harness.now.date = at(30)
        harness.controller.noteControlRefusal(.notRecording)
        await harness.controller.settle()

        harness.now.date = at(31)
        harness.controller.update(LiveActivityHarness.recordingRequest(at: at(31)))
        await harness.controller.settle()

        harness.now.date = at(61)
        harness.controller.update(
            LiveActivityHarness.recordingRequest(distanceMeters: 2000, at: at(61))
        )
        await harness.controller.settle()

        #expect(harness.controller.activeSubject == .recording(sessionID: LiveActivityHarness.sessionID))
        // The refusal on the follow, then the recording's update.
        #expect(harness.presenter.updatedStates.count == 2)
        #expect(harness.presenter.updatedStates.last?.controlRefusal == nil)
    }
}
