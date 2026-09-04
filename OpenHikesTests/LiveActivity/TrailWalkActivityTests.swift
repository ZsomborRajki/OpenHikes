//
//  TrailWalkActivityTests.swift
//  OpenHikesTests
//
//  That a walk along a followed trail reaches the Lock Screen and the
//  widget, and leaves them: its coverage and clock ride the same snapshot
//  the widget reads, a pause takes the run-state bypass, an end lingers with
//  the closing figures, an abandonment leaves nothing, and a recording still
//  outranks all of it.
//
//  The counterpart to `TrailFollowActivityTests`, with the same fixtures and
//  the same App Group precondition, split out only because that class had
//  reached its length.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesShared
import SwiftData
import Testing

extension WidgetFeedSuites {
@Suite("Trail walk Live Activity", .serialized)
final class TrailWalkActivityTests {
    private let container: ModelContainer
    private let context: ModelContext
    private let tracker: BackgroundTrailTracker
    private let controller: HikeLiveActivityController
    private let presenter: StubHikeActivityPresenter
    private let defaults: UserDefaults

    init() throws {
        container = try Fixture.modelContainer()
        context = ModelContext(container)
        defaults = try makeScratchDefaults()
        defaults.set(true, forKey: SettingsKey.liveActivitiesEnabled)
        presenter = StubHikeActivityPresenter()
        controller = HikeLiveActivityController(
            presenter: presenter,
            defaults: defaults
        )
        tracker = BackgroundTrailTracker(
            container: container,
            defaults: defaults,
            liveActivityController: controller
        )
        SharedStore.clear()
    }

    deinit {
        SharedStore.clear()
    }

    private func hike() -> Hike {
        Fixture.hike(in: context)
    }

    /// A session wired to this tracker, with a clock the test moves.
    private func walkSession(clock: TestClock) -> TrailWalkSession {
        TrailWalkSession(context: context, tracker: tracker, clock: clock.read)
    }

    /// Starts a walk along `hike` from its first three points, through the
    /// same path the detail view takes: match, then publish with the payload.
    private func startWalk(
        _ session: TrailWalkSession,
        hike: Hike,
        profile: RouteProfile,
        clock: TestClock
    ) async throws {
        for index in 0...2 {
            clock.advance(by: 60)
            session.recordForegroundMatch(hike: hike, profile: profile, distance: profile.distances[index])
        }
        let match = try #require(profile.nearestPoint(to: profile.coordinates[2]))
        tracker.publishLiveFix(hike: hike, profile: profile, match: match, walk: session.payload(for: hike.id))
        await tracker.waitForLiveFixPublish()
        await controller.settle()
    }

    /// The activity carries the walk's coverage, run state and clock — the
    /// same bytes the widget just received.
    @Test("a walk's coverage and clock reach the Lock Screen")
    func walkReachesTheLockScreen() async throws {
        let clock = TestClock()
        let session = walkSession(clock: clock)
        let hike = hike()
        let profile = RouteProfile(route: hike.route)
        tracker.hikeSelectionChanged(to: hike)
        await tracker.waitForSelectionPublish()

        try await startWalk(session, hike: hike, profile: profile, clock: clock)

        #expect(presenter.startedSubjects == [.following(hikeID: hike.id)])
        let state = try #require(presenter.startedStates.first)
        #expect(state.coveredFractionComplete == session.coveredFraction)
        #expect(state.runState == .running)
        // The walk began on the first match, a minute in; two more minutes
        // of matches followed.
        #expect(abs(state.elapsedSeconds - 120) < 1)
        let stored = try #require(SharedStore.load())
        #expect(stored.walk?.coveredFraction == session.coveredFraction)
        #expect(stored.statusText.contains("walked"))
    }

    /// Pausing reaches the panel at once, through the run-state bypass —
    /// not on the next fix, which a paused walk no longer publishes.
    @Test("pausing reaches the Lock Screen through the status bypass")
    func pauseReachesTheLockScreen() async throws {
        let clock = TestClock()
        let session = walkSession(clock: clock)
        let hike = hike()
        let profile = RouteProfile(route: hike.route)
        tracker.hikeSelectionChanged(to: hike)
        await tracker.waitForSelectionPublish()
        try await startWalk(session, hike: hike, profile: profile, clock: clock)

        clock.advance(by: 1)
        session.pause()
        await tracker.waitForLiveFixPublish()
        await controller.settle()

        let paused = try #require(presenter.updatedStates.last)
        #expect(paused.runState == .paused)
        #expect(SharedStore.load()?.walk?.state == .paused)
        #expect(SharedStore.load()?.statusText.hasPrefix("Paused") == true)
    }

    /// End leaves the closing figures on the Lock Screen for a while, the
    /// way a finished recording does — and takes the walk off the widget at
    /// once.
    @Test("ending a walk lingers with its final coverage")
    func endLingersWithTheFinalState() async throws {
        let clock = TestClock()
        let session = walkSession(clock: clock)
        let hike = hike()
        let profile = RouteProfile(route: hike.route)
        tracker.hikeSelectionChanged(to: hike)
        await tracker.waitForSelectionPublish()
        try await startWalk(session, hike: hike, profile: profile, clock: clock)
        let fraction = session.coveredFraction

        clock.advance(by: 1)
        let ended = try #require(session.end().walk)
        await tracker.waitForLiveFixPublish()
        await controller.settle()

        #expect(ended.endReason == .ended)
        guard case let .end(finalState, dismissAfter)? = presenter.calls.last else {
            Issue.record("ending the walk should end the activity, got \(presenter.calls)")
            return
        }
        let final = try #require(finalState)
        #expect(final.runState == .finished)
        #expect(final.coveredFractionComplete == fraction)
        #expect(dismissAfter == HikeLiveActivityController.finishedDismissAfter)
        #expect(SharedStore.load()?.walk == nil, "the widget flips back to the plain trail at once")
        #expect(tracker.walkedHikeID == nil)
    }

    /// The deferred selection used to be applied beside the walk's terminal
    /// write rather than after it. It bumped the revision that write was
    /// gated on, so the write was rejected, the completion carrying the
    /// closing figures never ran, and the panel came down with nothing — the
    /// abandoned walk's ending, for a walk the walker had just finished.
    @Test("a walk that ends with another trail waiting still lingers with its result")
    func endLingersWithASelectionWaiting() async throws {
        let clock = TestClock()
        let session = walkSession(clock: clock)
        let hike = hike()
        let profile = RouteProfile(route: hike.route)
        tracker.hikeSelectionChanged(to: hike)
        await tracker.waitForSelectionPublish()
        try await startWalk(session, hike: hike, profile: profile, clock: clock)
        let fraction = session.coveredFraction

        // Another trail opened to compare it: remembered, not applied.
        let other = Fixture.hike(in: context, title: "Compared", route: Fixture.loopRoute)
        tracker.hikeSelectionChanged(to: other)
        await tracker.waitForSelectionPublish()

        clock.advance(by: 1)
        session.end()
        await tracker.waitForLiveFixPublish()
        await tracker.waitForSelectionPublish()
        await controller.settle()

        guard case let .end(finalState, dismissAfter)? = presenter.calls.last else {
            Issue.record("ending the walk should end the activity, got \(presenter.calls)")
            return
        }
        let final = try #require(finalState, "the closing figures, not the abandoned walk's nothing")
        #expect(final.runState == .finished)
        #expect(final.coveredFractionComplete == fraction)
        #expect(dismissAfter == HikeLiveActivityController.finishedDismissAfter)
        #expect(tracker.trackedHikeID == other.id, "and the deferred selection still lands")
    }

    /// An abandoned walk has no result the walker was waiting for: the panel
    /// comes down with nothing on it.
    @Test("an abandoned walk ends with nothing")
    func abandonedEndsWithNothing() async throws {
        let clock = TestClock()
        let session = walkSession(clock: clock)
        let hike = hike()
        let profile = RouteProfile(route: hike.route)
        tracker.hikeSelectionChanged(to: hike)
        await tracker.waitForSelectionPublish()
        try await startWalk(session, hike: hike, profile: profile, clock: clock)

        clock.advance(by: TrailWalkPolicy.abandonAfter + 1)
        session.endIfAbandoned()
        await tracker.waitForLiveFixPublish()
        await controller.settle()

        #expect(presenter.calls.last == .end(finalState: nil, dismissAfter: nil))
        #expect(controller.activeSubject == nil)
    }

    /// Opening another trail to compare it is not leaving the walk: the
    /// tracked hike, the widget and the Lock Screen stay the walk's until it
    /// ends, and the new selection is applied then.
    @Test("a selection change during a walk changes nothing until the walk ends")
    func selectionIsDeferredDuringAWalk() async throws {
        let clock = TestClock()
        let session = walkSession(clock: clock)
        let hike = hike()
        let profile = RouteProfile(route: hike.route)
        tracker.hikeSelectionChanged(to: hike)
        await tracker.waitForSelectionPublish()
        try await startWalk(session, hike: hike, profile: profile, clock: clock)

        let other = Fixture.hike(in: context, title: "Compared", route: Fixture.loopRoute)
        tracker.hikeSelectionChanged(to: other)
        await tracker.waitForSelectionPublish()
        await controller.settle()

        #expect(tracker.trackedHikeID == hike.id)
        #expect(session.walkedHikeID == hike.id)
        #expect(SharedStore.load()?.hikeID == hike.id, "the widget keeps the walk")
        #expect(controller.activeSubject == .following(hikeID: hike.id))

        clock.advance(by: 1)
        session.end()
        await tracker.waitForLiveFixPublish()
        await tracker.waitForSelectionPublish()
        await controller.settle()
        #expect(tracker.trackedHikeID == other.id, "the deferred selection lands once the walk is over")
        #expect(SharedStore.load()?.hikeID == other.id)
    }

    /// A recording takes the screen from a walk exactly as it takes it from
    /// a follow; the walk keeps accruing silently and gets it back later.
    @Test("a recording still outranks a walk")
    func recordingOutranksAWalk() async throws {
        let clock = TestClock()
        let session = walkSession(clock: clock)
        let hike = hike()
        let profile = RouteProfile(route: hike.route)
        tracker.hikeSelectionChanged(to: hike)
        await tracker.waitForSelectionPublish()
        try await startWalk(session, hike: hike, profile: profile, clock: clock)

        let sessionID = UUID()
        controller.update(
            HikeActivityRequest(
                attributes: .recording(
                    sessionID: sessionID,
                    title: "Morning walk",
                    tintHex: Hike.defaultTintHex,
                    startedAt: .now
                ),
                state: .init(distanceMeters: 100)
            )
        )
        await controller.settle()
        #expect(controller.activeSubject == .recording(sessionID: sessionID))

        clock.advance(by: 60)
        session.recordForegroundMatch(hike: hike, profile: profile, distance: profile.distances[4])
        session.pause()
        await tracker.waitForLiveFixPublish()
        await controller.settle()

        #expect(controller.activeSubject == .recording(sessionID: sessionID), "the walk does not take it back")
        #expect(session.phase == .paused, "but the walk itself went on")
        #expect(session.coveredFraction > 0)
    }

}
}
