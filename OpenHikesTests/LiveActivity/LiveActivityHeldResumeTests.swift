//
//  LiveActivityHeldResumeTests.swift
//  OpenHikesTests
//
//  A resume inside the flip floor, with no fix after it. The recorder
//  publishes Resume at once, the controller refuses a run-state change
//  within ten seconds of the last, and the next fix was what offered it
//  again — so a hiker who paused, resumed and stood still kept a paused
//  panel with a frozen timer over a walk that was recording. The refused
//  resume is now held and offered again when the floor lifts.
//
//  Driven through `LiveActivityHarness`: its clock is moved by hand, and its
//  waits end when the test says, never by time passing.
//

import Foundation
@testable import OpenHikes
import OpenHikesShared
import Testing

@MainActor
@Suite("A resume the flip floor held back")
struct LiveActivityHeldResumeTests {
    private func at(_ seconds: TimeInterval) -> Date {
        LiveActivityHarness.start.addingTimeInterval(seconds)
    }

    /// Recording, then paused at 30 s: the pause lands, and starts the floor.
    private func pausedAtThirty() async -> LiveActivityHarness.Harness {
        let harness = LiveActivityHarness.harness()
        harness.controller.update(LiveActivityHarness.recordingRequest())
        harness.now.date = at(30)
        harness.controller.update(LiveActivityHarness.recordingRequest(runState: .paused, at: at(30)))
        await harness.controller.settle()
        return harness
    }

    @Test("a resume inside the floor lands when the floor lifts, with no fix after it")
    func heldResumeLandsWithoutAFix() async {
        let harness = await pausedAtThirty()
        #expect(harness.presenter.updatedStates.last?.runState == .paused)

        harness.now.date = at(33)
        harness.controller.update(LiveActivityHarness.recordingRequest(runState: .running, at: at(33)))
        await harness.controller.settle()
        #expect(harness.presenter.updatedStates.last?.runState == .paused, "precondition: inside the floor")
        await settleDelegateHop(until: "the held resume to wait out the floor") { harness.waits.isWaiting }
        #expect(harness.waits.requested == [HikeLiveActivityController.minimumFlipInterval - 3])

        harness.now.date = at(40)
        harness.waits.endAll()
        await settleDelegateHop(until: "the held resume to reach the panel") {
            harness.presenter.updatedStates.last?.runState == .running
        }
        await harness.controller.settle()

        #expect(harness.presenter.updatedStates.map(\.runState) == [.paused, .running])
    }

    /// The latest offer is the one held: a pause inside the floor lands at
    /// once, and the resume it undid is not delivered after it.
    @Test("a pause after a held resume cancels it")
    func pauseCancelsAHeldResume() async {
        let harness = await pausedAtThirty()
        harness.now.date = at(33)
        harness.controller.update(LiveActivityHarness.recordingRequest(runState: .running, at: at(33)))
        await settleDelegateHop(until: "the held resume to wait out the floor") { harness.waits.isWaiting }

        harness.now.date = at(41)
        harness.controller.update(LiveActivityHarness.recordingRequest(runState: .paused, at: at(41)))
        await harness.controller.settle()
        await settleDelegateHop(until: "the held resume's wait to be cancelled") { !harness.waits.isWaiting }

        #expect(harness.presenter.updatedStates.map(\.runState) == [.paused])
    }

    @Test("a walk that ends while a resume is held is not resumed on the panel")
    func endCancelsAHeldResume() async {
        let harness = await pausedAtThirty()
        harness.now.date = at(33)
        harness.controller.update(LiveActivityHarness.recordingRequest(runState: .running, at: at(33)))
        await settleDelegateHop(until: "the held resume to wait out the floor") { harness.waits.isWaiting }

        harness.controller.end(subject: .recording(sessionID: LiveActivityHarness.sessionID), finalState: nil)
        await harness.controller.settle()
        await settleDelegateHop(until: "the held resume's wait to be cancelled") { !harness.waits.isWaiting }

        #expect(harness.presenter.updatedStates.map(\.runState) == [.paused])
        #expect(harness.presenter.endCount == 1)
    }
}
