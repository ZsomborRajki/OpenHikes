//
//  LiveActivityStatusFloorTests.swift
//  OpenHikesTests
//
//  The two floors under the status-change bypass, and the one transition that
//  is not floored at all.
//
//  Split from ``HikeLiveActivityControllerTests`` because it pins a different
//  claim from the rest of the throttling assertions there. Those ask *whether*
//  a status change bypasses the update interval; these ask what happens when
//  two status changes compete, which is where the panel used to be left saying
//  the opposite of the truth: a run-state change and an on/off-route change
//  shared one clock and one ten-second floor, so a walker who stepped off the
//  route and paused a few seconds later had the pause refused by a floor that
//  exists to damp GPS noise — and refused for good, because
//  `HikeRecorder.pause()` stops the location sensors, so no later fix arrives
//  to carry the correction.
//
//  Everything here drives the injected clock by hand. The controller's whole
//  job is deciding what is worth doing *yet*, so a suite that waited out a
//  ten-second floor would be measuring `Task.sleep`.
//

import Foundation
@testable import OpenHikes
import OpenHikesShared
import Testing

@MainActor
@Suite("Hike Live Activity status floors")
struct LiveActivityStatusFloorTests {
    /// Seconds after the harness's fixed epoch. Named because every assertion
    /// below is a statement about *when*, and `start.addingTimeInterval(11)`
    /// buries that under arithmetic.
    private func at(_ seconds: TimeInterval) -> Date {
        LiveActivityHarness.start.addingTimeInterval(seconds)
    }

    /// A second recording session, so a replacement `start` can be reached
    /// without an `end` in between — which is the only way to tell the clock
    /// resets in `start` apart from the identical ones in `finish`.
    private func otherRecording(
        sessionID: UUID,
        runState: HikeActivityAttributes.ContentState.RunState,
        at date: Date
    ) -> HikeActivityRequest {
        HikeActivityRequest(
            attributes: .recording(
                sessionID: sessionID,
                title: "Afternoon walk",
                tintHex: "#34C759",
                startedAt: LiveActivityHarness.start
            ),
            state: .init(
                distanceMeters: 1000,
                runState: runState,
                elapsedSeconds: 600,
                updatedAt: date
            )
        )
    }

    // MARK: A pause is never refused

    /// The finding, stated at the controller's own API: a route flip takes the
    /// bypass, and a pause arriving inside the following ten seconds still has
    /// to land.
    ///
    /// A pause is not GPS noise. It is a deliberate tap, and it is the last
    /// thing this controller will hear about the walk until the walker acts
    /// again — so a refusal here is permanent, and the panel goes on reading
    /// "Recording" with its self-ticking clock still counting.
    @Test("a pause is not refused by a route flip that just happened")
    func pauseSurvivesARecentRouteFlip() async {
        let harness = LiveActivityHarness.harness()
        harness.controller.update(LiveActivityHarness.recordingRequest(offRouteMeters: 4))
        await harness.controller.settle()

        harness.now.date = at(1)
        harness.controller.update(
            LiveActivityHarness.recordingRequest(offRouteMeters: nil, at: at(1))
        )
        await harness.controller.settle()
        #expect(harness.presenter.updatedStates.count == 1)

        harness.now.date = at(3)
        harness.controller.update(
            LiveActivityHarness.recordingRequest(runState: .paused, offRouteMeters: nil, at: at(3))
        )
        await harness.controller.settle()
        #expect(harness.presenter.updatedStates.count == 2)
        #expect(harness.presenter.updatedStates.last?.runState == .paused)
    }

    /// The same refusal reached the way the shipping app actually reaches it.
    ///
    /// A recording's `ContentState` never carries `offRouteMeters` — see
    /// `ContentState.init(recording:elapsedSeconds:)` — so the two halves of
    /// the old shared floor could only collide through run-state changes
    /// themselves. Resume, then think better of it: the resume consumes the
    /// floor and the second pause is thrown away.
    @Test("a pause is not refused by a resume that just happened")
    func pauseSurvivesARecentResume() async {
        let harness = LiveActivityHarness.harness()
        harness.controller.update(LiveActivityHarness.recordingRequest())
        await harness.controller.settle()

        harness.now.date = at(1)
        harness.controller.update(
            LiveActivityHarness.recordingRequest(runState: .paused, at: at(1))
        )
        await harness.controller.settle()

        harness.now.date = at(12)
        harness.controller.update(
            LiveActivityHarness.recordingRequest(runState: .running, at: at(12))
        )
        await harness.controller.settle()
        #expect(harness.presenter.updatedStates.count == 2)
        #expect(harness.presenter.updatedStates.last?.runState == .running)

        harness.now.date = at(15)
        harness.controller.update(
            LiveActivityHarness.recordingRequest(runState: .paused, at: at(15))
        )
        await harness.controller.settle()
        #expect(harness.presenter.updatedStates.count == 3)
        #expect(harness.presenter.updatedStates.last?.runState == .paused)
    }

    // MARK: The clocks are separate

    /// A resume is floored — it has a retry, so it can be made to wait — but
    /// by *its own* clock. A route flip must not spend it.
    ///
    /// Deliberately a resume rather than a pause: a pause bypasses the floor
    /// outright, so it would pass whether or not the clocks were shared, and
    /// would say nothing about the separation.
    @Test("a route flip does not spend the run-state floor")
    func routeFlipDoesNotSpendTheRunStateFloor() async {
        let harness = LiveActivityHarness.harness()
        harness.controller.update(
            LiveActivityHarness.recordingRequest(runState: .paused, offRouteMeters: 4)
        )
        await harness.controller.settle()

        harness.now.date = at(1)
        harness.controller.update(
            LiveActivityHarness.recordingRequest(runState: .paused, offRouteMeters: nil, at: at(1))
        )
        await harness.controller.settle()
        #expect(harness.presenter.updatedStates.count == 1)

        harness.now.date = at(3)
        harness.controller.update(
            LiveActivityHarness.recordingRequest(runState: .running, offRouteMeters: nil, at: at(3))
        )
        await harness.controller.settle()
        #expect(harness.presenter.updatedStates.count == 2)
        #expect(harness.presenter.updatedStates.last?.runState == .running)
    }

    // MARK: The route floor is still a floor

    /// The converse, and the reason none of the above is just "the floor was
    /// deleted": a second route flip inside ten seconds is still refused, and
    /// a run-state change landing in between does not buy it a free pass.
    ///
    /// The zero in the middle is sandwiched between two positives on purpose.
    /// Without them it would only be evidence that nothing was happening.
    @Test("a route flip inside the floor is still refused")
    func routeFlipInsideTheFloorIsRefused() async {
        let harness = LiveActivityHarness.harness()
        harness.controller.update(LiveActivityHarness.recordingRequest(offRouteMeters: 4))
        await harness.controller.settle()

        harness.now.date = at(1)
        harness.controller.update(
            LiveActivityHarness.recordingRequest(offRouteMeters: nil, at: at(1))
        )
        await harness.controller.settle()
        #expect(harness.presenter.updatedStates.count == 1)

        harness.now.date = at(2)
        harness.controller.update(
            LiveActivityHarness.recordingRequest(runState: .paused, offRouteMeters: nil, at: at(2))
        )
        await harness.controller.settle()
        #expect(harness.presenter.updatedStates.count == 2)

        harness.now.date = at(3)
        harness.controller.update(
            LiveActivityHarness.recordingRequest(runState: .paused, offRouteMeters: 3, at: at(3))
        )
        await harness.controller.settle()
        #expect(harness.presenter.updatedStates.count == 2)

        // Ten seconds after the flip that spent it, not after the run-state
        // change that landed in between — which is the whole claim.
        harness.now.date = at(11)
        harness.controller.update(
            LiveActivityHarness.recordingRequest(runState: .paused, offRouteMeters: 3, at: at(11))
        )
        await harness.controller.settle()
        #expect(harness.presenter.updatedStates.count == 3)
    }

    // MARK: The rate is still bounded

    /// What the unfloored pause costs, which is nothing: the controller only
    /// emits when the run state differs from what is on screen, and a refused
    /// resume leaves that belief alone — so pauses and resumes strictly
    /// alternate and flooring the resume floors the pair.
    ///
    /// Ten seconds of hammering Pause and Resume once a second buys one
    /// update, which is exactly the ceiling the route floor imposes on its own
    /// kind. This is the assertion that makes an unconditional bypass a
    /// rejected alternative rather than an untested one:
    /// `NSSupportsLiveActivitiesFrequentUpdates` is deliberately absent, so
    /// the ordinary budget is all there is to spend.
    @Test("hammering pause and resume cannot outrun the floor")
    func hammeringPauseAndResumeIsBounded() async {
        let harness = LiveActivityHarness.harness()
        harness.controller.update(LiveActivityHarness.recordingRequest())
        await harness.controller.settle()

        for second in 1...10 {
            harness.now.date = at(TimeInterval(second))
            harness.controller.update(
                LiveActivityHarness.recordingRequest(
                    runState: second.isMultiple(of: 2) ? .running : .paused,
                    at: at(TimeInterval(second))
                )
            )
            await harness.controller.settle()
        }
        #expect(harness.presenter.updatedStates.count == 1)
        #expect(harness.presenter.updatedStates.last?.runState == .paused)

        harness.now.date = at(11)
        harness.controller.update(
            LiveActivityHarness.recordingRequest(runState: .running, at: at(11))
        )
        await harness.controller.settle()
        #expect(harness.presenter.updatedStates.count == 2)
        #expect(harness.presenter.updatedStates.last?.runState == .running)
    }

    /// The premise the bound above rests on, asserted rather than assumed: a
    /// refused update does not advance what the controller believes is on
    /// screen, so the refusal is a deferral for anything that keeps arriving.
    ///
    /// This is why a resume can be floored safely and a pause cannot — the
    /// fixes that would re-offer a resume are still running, and the ones that
    /// would re-offer a pause have been stopped.
    @Test("a refused resume is re-offered rather than forgotten")
    func refusedResumeIsRetried() async {
        let harness = LiveActivityHarness.harness()
        harness.controller.update(LiveActivityHarness.recordingRequest())
        await harness.controller.settle()

        harness.now.date = at(1)
        harness.controller.update(
            LiveActivityHarness.recordingRequest(runState: .paused, at: at(1))
        )
        await harness.controller.settle()
        #expect(harness.presenter.updatedStates.last?.runState == .paused)

        harness.now.date = at(2)
        harness.controller.update(
            LiveActivityHarness.recordingRequest(runState: .running, at: at(2))
        )
        await harness.controller.settle()
        #expect(harness.presenter.updatedStates.count == 1)

        harness.now.date = at(11)
        harness.controller.update(
            LiveActivityHarness.recordingRequest(runState: .running, at: at(11))
        )
        await harness.controller.settle()
        #expect(harness.presenter.updatedStates.count == 2)
        #expect(harness.presenter.updatedStates.last?.runState == .running)
    }

    // MARK: A new walk inherits neither clock

    /// A walk that takes the screen from another one starts with both floors
    /// clear, exactly as it starts with the update interval clear: the first
    /// thing the walker is told about *this* walk must not be held back by
    /// something the last one spent.
    ///
    /// Reached through a replacement rather than an end, because `finish`
    /// clears the same two fields and would mask the ones in `start`.
    @Test("a replacing walk does not inherit the run-state floor")
    func replacementClearsTheRunStateFloor() async {
        let harness = LiveActivityHarness.harness()
        harness.controller.update(LiveActivityHarness.recordingRequest())
        await harness.controller.settle()

        harness.now.date = at(1)
        harness.controller.update(
            LiveActivityHarness.recordingRequest(runState: .paused, at: at(1))
        )
        await harness.controller.settle()
        #expect(harness.presenter.updatedStates.count == 1)

        let second = UUID()
        harness.now.date = at(2)
        harness.controller.update(
            otherRecording(sessionID: second, runState: .paused, at: at(2))
        )
        await harness.controller.settle()
        #expect(harness.presenter.startedSubjects.count == 2)

        harness.now.date = at(3)
        harness.controller.update(
            otherRecording(sessionID: second, runState: .running, at: at(3))
        )
        await harness.controller.settle()
        #expect(harness.presenter.updatedStates.count == 2)
        #expect(harness.presenter.updatedStates.last?.runState == .running)
    }

    @Test("a replacing walk does not inherit the route floor")
    func replacementClearsTheRouteFloor() async {
        let harness = LiveActivityHarness.harness()
        harness.controller.update(LiveActivityHarness.followingRequest())
        await harness.controller.settle()

        harness.now.date = at(1)
        harness.controller.update(
            LiveActivityHarness.followingRequest(offRouteMeters: nil, at: at(1))
        )
        await harness.controller.settle()
        #expect(harness.presenter.updatedStates.count == 1)

        harness.now.date = at(2)
        harness.controller.update(
            LiveActivityHarness.recordingRequest(offRouteMeters: nil, at: at(2))
        )
        await harness.controller.settle()
        #expect(harness.presenter.startedSubjects.count == 2)

        harness.now.date = at(3)
        harness.controller.update(
            LiveActivityHarness.recordingRequest(offRouteMeters: 3, at: at(3))
        )
        await harness.controller.settle()
        #expect(harness.presenter.updatedStates.count == 2)
        #expect(harness.presenter.updatedStates.last?.offRouteMeters == 3)
    }
}
