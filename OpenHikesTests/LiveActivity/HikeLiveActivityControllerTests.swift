//
//  HikeLiveActivityControllerTests.swift
//  OpenHikesTests
//
//  What the app decides about the Lock Screen, without ActivityKit in the way.
//
//  ActivityKit cannot be exercised from a hosted unit test at all: under
//  `xcodebuild test` `ActivityAuthorizationInfo` reports activities disabled
//  and `Activity.request` throws, and nothing makes either say otherwise. A
//  suite talking to the framework could therefore only assert that nothing
//  happened. Everything worth asserting — precedence between a recording and a
//  followed trail, what an update is worth, what is left on screen after a
//  walk ends — is policy, and lives above the ``HikeActivityPresenting`` seam
//  where a stub can watch it.
//

import Foundation
@testable import OpenHikes
import OpenHikesShared
import Testing

/// Records what the controller asked ActivityKit to do, and answers the one
/// question ActivityKit would: whether the walker allows any of this.
@MainActor
final class StubHikeActivityPresenter: HikeActivityPresenting {
    enum Call: Equatable {
        case start(HikeActivityAttributes.Subject)
        case update(HikeActivityAttributes.ContentState)
        case end(finalState: HikeActivityAttributes.ContentState?, dismissAfter: TimeInterval?)
    }

    var areActivitiesEnabled = true
    private(set) var calls: [Call] = []
    private(set) var staleIntervals: [TimeInterval] = []
    private var subject: HikeActivityAttributes.Subject?

    var activeSubject: HikeActivityAttributes.Subject? { subject }

    var startedSubjects: [HikeActivityAttributes.Subject] {
        calls.compactMap { call in
            if case .start(let subject) = call { return subject }
            return nil
        }
    }

    var updatedStates: [HikeActivityAttributes.ContentState] {
        calls.compactMap { call in
            if case .update(let state) = call { return state }
            return nil
        }
    }

    /// The states that came with a `start`, kept beside the subjects so a
    /// wiring test can assert on the first thing the walker saw.
    private(set) var startedStates: [HikeActivityAttributes.ContentState] = []

    var endCount: Int {
        calls.count { call in
            if case .end = call { return true }
            return false
        }
    }

    func start(
        _ attributes: HikeActivityAttributes,
        state: HikeActivityAttributes.ContentState,
        staleAfter: TimeInterval
    ) {
        subject = attributes.subject
        staleIntervals.append(staleAfter)
        startedStates.append(state)
        calls.append(.start(attributes.subject))
    }

    func update(
        _ state: HikeActivityAttributes.ContentState,
        staleAfter: TimeInterval
    ) {
        staleIntervals.append(staleAfter)
        calls.append(.update(state))
    }

    func end(
        finalState: HikeActivityAttributes.ContentState?,
        dismissAfter: TimeInterval?
    ) {
        subject = nil
        calls.append(.end(finalState: finalState, dismissAfter: dismissAfter))
    }
}

@MainActor
@Suite("Hike Live Activity controller")
struct HikeLiveActivityControllerTests {
    // MARK: Starting

    @Test("the first update starts an activity")
    func firstUpdateStarts() async {
        let harness = LiveActivityHarness.harness()
        harness.controller.update(LiveActivityHarness.recordingRequest())
        await harness.controller.settle()
        #expect(harness.presenter.startedSubjects == [.recording(sessionID: LiveActivityHarness.sessionID)])
        #expect(harness.controller.activeSubject == .recording(sessionID: LiveActivityHarness.sessionID))
    }

    /// The app's own switch. Read on every call rather than captured, so this
    /// also covers turning it off mid-walk — see below.
    @Test("the app's switch is respected")
    func disabledPreferenceStartsNothing() async {
        let harness = LiveActivityHarness.harness(liveActivities: false)
        harness.controller.update(LiveActivityHarness.recordingRequest())
        await harness.controller.settle()
        #expect(harness.presenter.calls.isEmpty)
        #expect(!harness.controller.isEnabled)
    }

    /// The system's switch is the walker's veto and the app cannot argue with
    /// it. Distinct from the app's own preference, which is why both are
    /// consulted.
    @Test("the system's switch is respected")
    func systemDisabledStartsNothing() async {
        let harness = LiveActivityHarness.harness()
        harness.presenter.areActivitiesEnabled = false
        harness.controller.update(LiveActivityHarness.recordingRequest())
        await harness.controller.settle()
        #expect(harness.presenter.calls.isEmpty)
    }

    /// An activity already on the Lock Screen has to come down when the switch
    /// goes off, rather than freeze there reporting a walk nobody is watching.
    @Test("turning the switch off mid-walk takes the activity down")
    func disablingMidWalkEndsTheActivity() async {
        let presenter = StubHikeActivityPresenter()
        let defaults = LiveActivityHarness.defaults()
        let controller = HikeLiveActivityController(
            presenter: presenter,
            defaults: defaults,
            clock: { LiveActivityHarness.start }
        )
        controller.update(LiveActivityHarness.recordingRequest())
        await controller.settle()
        #expect(presenter.activeSubject != nil)

        defaults.set(false, forKey: SettingsKey.liveActivitiesEnabled)
        controller.update(LiveActivityHarness.recordingRequest(distanceMeters: 2000))
        await controller.settle()
        #expect(presenter.endCount == 1)
        #expect(controller.activeSubject == nil)
    }

    // MARK: Precedence

    /// They genuinely overlap — a walker records their own track along an
    /// imported route — and the system shows one activity.
    @Test("a recording takes the screen from a followed trail")
    func recordingOutranksFollowing() async {
        let harness = LiveActivityHarness.harness()
        harness.controller.update(LiveActivityHarness.followingRequest())
        await harness.controller.settle()
        #expect(harness.controller.activeSubject == .following(hikeID: LiveActivityHarness.hikeID))

        harness.controller.update(LiveActivityHarness.recordingRequest())
        await harness.controller.settle()
        #expect(harness.controller.activeSubject == .recording(sessionID: LiveActivityHarness.sessionID))
        #expect(harness.presenter.startedSubjects.last == .recording(sessionID: LiveActivityHarness.sessionID))
    }

    /// The replacement is *ordered*: two activities of one attributes type can
    /// be on the Lock Screen at once, so the follow has to be gone before the
    /// recording arrives.
    @Test("the followed trail is ended before the recording starts")
    func replacementEndsBeforeItStarts() async throws {
        let harness = LiveActivityHarness.harness()
        harness.controller.update(LiveActivityHarness.followingRequest())
        await harness.controller.settle()
        harness.controller.update(LiveActivityHarness.recordingRequest())
        await harness.controller.settle()

        let endIndex = try #require(
            harness.presenter.calls.firstIndex { call in
                if case .end = call { return true }
                return false
            }
        )
        let recordingStart = try #require(
            harness.presenter.calls.firstIndex(
                of: .start(.recording(sessionID: LiveActivityHarness.sessionID))
            )
        )
        #expect(endIndex < recordingStart)
    }

    @Test("a followed trail never takes the screen from a recording")
    func followingDoesNotOutrankRecording() async {
        let harness = LiveActivityHarness.harness()
        harness.controller.update(LiveActivityHarness.recordingRequest())
        await harness.controller.settle()
        harness.controller.update(LiveActivityHarness.followingRequest())
        await harness.controller.settle()
        #expect(harness.controller.activeSubject == .recording(sessionID: LiveActivityHarness.sessionID))
        #expect(harness.presenter.startedSubjects.count == 1)
    }

    // MARK: Throttling

    /// The reason the callers can publish at fix rate without doing this
    /// arithmetic themselves.
    @Test("a second update inside the interval is dropped")
    func updatesAreThrottled() async {
        let harness = LiveActivityHarness.harness()
        harness.controller.update(LiveActivityHarness.recordingRequest())
        await harness.controller.settle()

        harness.now.date = LiveActivityHarness.start.addingTimeInterval(5)
        harness.controller.update(
            LiveActivityHarness.recordingRequest(distanceMeters: 5000, at: harness.now.date)
        )
        await harness.controller.settle()
        #expect(harness.presenter.updatedStates.isEmpty)
    }

    @Test("an update past the interval and the distance threshold lands")
    func updatesPastTheIntervalLand() async {
        let harness = LiveActivityHarness.harness()
        harness.controller.update(LiveActivityHarness.recordingRequest())
        await harness.controller.settle()

        harness.now.date = LiveActivityHarness.start.addingTimeInterval(
            HikeLiveActivityController.minimumUpdateInterval
        )
        harness.controller.update(
            LiveActivityHarness.recordingRequest(distanceMeters: 1100, at: harness.now.date)
        )
        await harness.controller.settle()
        #expect(harness.presenter.updatedStates.count == 1)
    }

    /// The interval alone is not enough: a walker standing still for a minute
    /// has nothing new to report, and spending the budget on it is what the
    /// distance threshold exists to prevent.
    @Test("time alone does not buy an update")
    func standingStillIsNotWorthAnUpdate() async {
        let harness = LiveActivityHarness.harness()
        harness.controller.update(LiveActivityHarness.recordingRequest())
        await harness.controller.settle()

        harness.now.date = LiveActivityHarness.start.addingTimeInterval(600)
        harness.controller.update(
            LiveActivityHarness.recordingRequest(distanceMeters: 1001, at: harness.now.date)
        )
        await harness.controller.settle()
        #expect(harness.presenter.updatedStates.isEmpty)
    }

    /// Pausing changes what the activity *says*, so it must never wait out the
    /// throttle.
    @Test("pausing bypasses the throttle")
    func pausingBypassesTheThrottle() async {
        let harness = LiveActivityHarness.harness()
        harness.controller.update(LiveActivityHarness.recordingRequest())
        await harness.controller.settle()

        harness.now.date = LiveActivityHarness.start.addingTimeInterval(1)
        harness.controller.update(
            LiveActivityHarness.recordingRequest(runState: .paused, at: harness.now.date)
        )
        await harness.controller.settle()
        #expect(harness.presenter.updatedStates.last?.isPaused == true)
    }

    @Test("losing the trail bypasses the throttle")
    func leavingTheTrailBypassesTheThrottle() async {
        let harness = LiveActivityHarness.harness()
        harness.controller.update(LiveActivityHarness.followingRequest())
        await harness.controller.settle()

        harness.now.date = LiveActivityHarness.start.addingTimeInterval(1)
        harness.controller.update(
            LiveActivityHarness.followingRequest(offRouteMeters: nil, at: harness.now.date)
        )
        await harness.controller.settle()
        #expect(harness.presenter.updatedStates.count == 1)
        #expect(harness.presenter.updatedStates.last?.offRouteMeters == nil)
    }

    /// Unbounded, the bypass is a hole straight through the throttle it
    /// bypasses — a walker flapping either side of the follow threshold would
    /// take it on every fix. The first flip is free; a second one waits.
    @Test("a second status flip inside the floor waits")
    func flipBypassHasAFloor() async {
        let harness = LiveActivityHarness.harness()
        harness.controller.update(LiveActivityHarness.followingRequest())
        await harness.controller.settle()

        harness.now.date = LiveActivityHarness.start.addingTimeInterval(1)
        harness.controller.update(
            LiveActivityHarness.followingRequest(offRouteMeters: nil, at: harness.now.date)
        )
        await harness.controller.settle()
        #expect(harness.presenter.updatedStates.count == 1)

        harness.now.date = LiveActivityHarness.start.addingTimeInterval(2)
        harness.controller.update(
            LiveActivityHarness.followingRequest(offRouteMeters: 3, at: harness.now.date)
        )
        await harness.controller.settle()
        #expect(harness.presenter.updatedStates.count == 1)
    }

    @Test("a status flip past the floor lands")
    func flipBypassResumesPastTheFloor() async {
        let harness = LiveActivityHarness.harness()
        harness.controller.update(LiveActivityHarness.followingRequest())
        await harness.controller.settle()

        harness.now.date = LiveActivityHarness.start.addingTimeInterval(1)
        harness.controller.update(
            LiveActivityHarness.followingRequest(offRouteMeters: nil, at: harness.now.date)
        )
        await harness.controller.settle()

        harness.now.date = harness.now.date.addingTimeInterval(
            HikeLiveActivityController.minimumFlipInterval
        )
        harness.controller.update(
            LiveActivityHarness.followingRequest(offRouteMeters: 3, at: harness.now.date)
        )
        await harness.controller.settle()
        #expect(harness.presenter.updatedStates.count == 2)
    }
}

/// The other half of the controller's job, split from
/// ``HikeLiveActivityControllerTests`` for length. Everything either suite
/// needs lives in ``LiveActivityHarness``.
@MainActor
@Suite("Hike Live Activity teardown")
struct HikeLiveActivityTeardownTests {
    @Test("ending the running subject takes it down")
    func endingTheRunningSubject() async {
        let harness = LiveActivityHarness.harness()
        harness.controller.update(LiveActivityHarness.recordingRequest())
        await harness.controller.settle()

        harness.controller.end(
            subject: .recording(sessionID: LiveActivityHarness.sessionID),
            finalState: LiveActivityHarness.recordingRequest(runState: .finished).state,
            dismissAfter: HikeLiveActivityController.finishedDismissAfter
        )
        await harness.controller.settle()
        #expect(harness.controller.activeSubject == nil)
        #expect(
            harness.presenter.calls.last == .end(
                finalState: LiveActivityHarness.recordingRequest(runState: .finished).state,
                dismissAfter: HikeLiveActivityController.finishedDismissAfter
            )
        )
    }

    /// A follow ending while a recording holds the screen must not take the
    /// recording down with it — which is exactly what an unguarded end would
    /// do, because both callers fire for walks that already lost the screen.
    @Test("ending a subject that is not on screen does nothing")
    func endingAnInactiveSubjectDoesNothing() async {
        let harness = LiveActivityHarness.harness()
        harness.controller.update(LiveActivityHarness.recordingRequest())
        await harness.controller.settle()

        harness.controller.end(subject: .following(hikeID: LiveActivityHarness.hikeID))
        await harness.controller.settle()
        #expect(harness.controller.activeSubject == .recording(sessionID: LiveActivityHarness.sessionID))
        #expect(harness.presenter.endCount == 0)
    }

    @Test("ending everything leaves nothing running")
    func endAllTakesWhateverIsUp() async {
        let harness = LiveActivityHarness.harness()
        harness.controller.update(LiveActivityHarness.followingRequest())
        await harness.controller.settle()

        harness.controller.endAll()
        await harness.controller.settle()
        #expect(harness.controller.activeSubject == nil)
        #expect(harness.presenter.endCount == 1)
    }

    /// A second end is not a second call. Both recording teardown paths run
    /// beside a shared-state clear that can itself return early, so an
    /// idempotent end is what stops a retry from ending an activity that
    /// belongs to the next walk.
    @Test("ending twice ends once")
    func endingIsIdempotent() async {
        let harness = LiveActivityHarness.harness()
        harness.controller.update(LiveActivityHarness.recordingRequest())
        await harness.controller.settle()

        harness.controller.endAll()
        harness.controller.endAll()
        await harness.controller.settle()
        #expect(harness.presenter.endCount == 1)
    }

    /// A restart after an end is a fresh activity, not a resumed one — and it
    /// must not inherit the previous walk's throttle, or the first thing the
    /// walker sees would be up to twenty seconds stale.
    @Test("a new walk after an end starts immediately")
    func restartingIsNotThrottled() async {
        let harness = LiveActivityHarness.harness()
        harness.controller.update(LiveActivityHarness.recordingRequest())
        await harness.controller.settle()
        harness.controller.endAll()
        await harness.controller.settle()

        harness.now.date = LiveActivityHarness.start.addingTimeInterval(1)
        harness.controller.update(LiveActivityHarness.followingRequest(at: harness.now.date))
        await harness.controller.settle()
        #expect(harness.presenter.startedSubjects.count == 2)
        #expect(harness.controller.activeSubject == .following(hikeID: LiveActivityHarness.hikeID))
    }

    // MARK: Staleness

    /// A recording updates once a fix, so silence means the fixes stopped. A
    /// follow is throttled to significant-change events in the background, so
    /// the same silence is an ordinary walk in a valley.
    @Test("the two subjects go stale on different terms")
    func staleDatesDifferBySubject() async {
        let harness = LiveActivityHarness.harness()
        harness.controller.update(LiveActivityHarness.recordingRequest())
        await harness.controller.settle()
        #expect(
            harness.presenter.staleIntervals.last
                == HikeLiveActivityController.recordingStaleAfter
        )

        harness.controller.endAll()
        await harness.controller.settle()
        harness.controller.update(LiveActivityHarness.followingRequest())
        await harness.controller.settle()
        #expect(
            harness.presenter.staleIntervals.last
                == HikeLiveActivityController.followingStaleAfter
        )
    }
}
