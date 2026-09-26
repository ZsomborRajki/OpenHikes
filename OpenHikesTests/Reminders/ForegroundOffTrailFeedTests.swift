//
//  ForegroundOffTrailFeedTests.swift
//  OpenHikesTests
//
//  That the foreground feed carries a departure all the way to the reminder.
//
//  `MovementReminderControllerTests+OffTrail` pins when the reminder speaks,
//  given distances. This pins that the distances arrive: from the match
//  `HikeDetailView`'s follow loop makes, through `publishLiveFix` and the walk
//  session, to the controller. Both halves of that used to drop it. The view
//  handed the tracker `nil` for any match further out than it would draw, so
//  the controller only ever heard of distances inside the follow threshold —
//  half the off-trail one — and the tracker reported whatever did reach it
//  only when the widget's 45-second throttle let a write through, so the
//  dwell was timed from whichever fix happened to publish.
//
//  Hosted by the widget-feed parent because `publishLiveFix` writes the App
//  Group snapshot, and with a clock of its own because the throttle it has to
//  get past reads one.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import OpenHikesShared
import SwiftData
import Testing

extension WidgetFeedSuites {
@Suite("Foreground off-trail feed", .serialized)
final class ForegroundOffTrailFeedTests {
    /// Ten seconds between fixes: well inside the foreground feed's 45-second
    /// throttle, which is what makes the dwell below a test of reporting every
    /// fix rather than every publish.
    private static let fixInterval: TimeInterval = 10
    /// A minute between the matches that start the walk, so each one clears
    /// the throttle the way `TrailWalkEndBoundaryTests` spaces them.
    private static let walkStartInterval: TimeInterval = 60
    /// Comfortably past ``MovementReminderPolicy/offTrailMeters``, and far
    /// past the follow threshold the detail view draws within.
    private static let wellOff = 400.0
    private static let fixesPerDwell = Int(MovementReminderPolicy.offTrailDwell / fixInterval)

    private let context: ModelContext
    private let clock: TestClock
    private let tracker: BackgroundTrailTracker
    private let session: TrailWalkSession
    private let reminders: MovementReminderHarness.Harness
    private let defaults: UserDefaults

    init() throws {
        clock = TestClock()
        let container = try Fixture.modelContainer()
        context = ModelContext(container)
        defaults = try makeScratchDefaults()
        tracker = BackgroundTrailTracker(
            container: container,
            monitor: StubLocationMonitor(),
            defaults: defaults,
            clock: clock.read
        )
        reminders = MovementReminderHarness.harness()
        session = TrailWalkSession(
            context: context,
            tracker: tracker,
            reminders: reminders.controller,
            clock: clock.read
        )
        SharedStore.clear()
    }

    deinit {
        SharedStore.clear()
    }

    /// A selected trail with a walk under way along it.
    private func walkingHike() async throws -> (Hike, RouteProfile) {
        let hike = Fixture.hike(in: context)
        try context.save()
        tracker.hikeSelectionChanged(to: hike)
        await tracker.waitForSelectionPublish()
        let profile = RouteProfile(route: hike.route)
        for index in 0...2 {
            clock.advance(by: Self.walkStartInterval)
            try follow(hike, profile: profile, onRouteAt: index)
        }
        try #require(session.isWalking(hike.id), "precondition: the walk has started")
        return (hike, profile)
    }

    /// A fix on the line, along the path `HikeDetailView.updateLiveFollow`
    /// takes for one: extend the walk, then publish the match.
    private func follow(_ hike: Hike, profile: RouteProfile, onRouteAt index: Int) throws {
        let match = try #require(profile.nearestPoint(to: profile.coordinates[index]))
        let completed = session.recordForegroundMatch(
            hike: hike,
            profile: profile,
            distance: match.distanceAlongRoute
        )
        guard !completed, session.publishes(hikeID: hike.id) else { return }
        tracker.publishLiveFix(hike: hike, profile: profile, match: match, walk: session.payload(for: hike.id))
    }

    /// A fix the matcher placed ``wellOff`` from the line, along the path the
    /// view takes for one: the walk hears it left, and the tracker is handed
    /// the match itself rather than `nil`.
    private func follow(_ hike: Hike, profile: RouteProfile, offRouteAfter seconds: TimeInterval) {
        clock.advance(by: seconds)
        let match = (distanceAlongRoute: profile.distances[2], offRouteMeters: Self.wellOff)
        session.recordOffRoute(hikeID: hike.id)
        guard session.publishes(hikeID: hike.id) else { return }
        tracker.publishLiveFix(hike: hike, profile: profile, match: match, walk: session.payload(for: hike.id))
    }

    /// Walks off the line and stays there for one dwell, a fix every
    /// ``fixInterval``, and answers what the hiker was told just short of it.
    private func leaveForADwell(_ hike: Hike, profile: RouteProfile) async -> [MovementReminderKind] {
        follow(hike, profile: profile, offRouteAfter: Self.fixInterval)
        for _ in 1..<Self.fixesPerDwell {
            follow(hike, profile: profile, offRouteAfter: Self.fixInterval)
        }
        await reminders.controller.settle()
        let beforeTheDwell = reminders.notifier.postedKinds
        follow(hike, profile: profile, offRouteAfter: Self.fixInterval)
        await reminders.controller.settle()
        await tracker.waitForLiveFixPublish()
        return beforeTheDwell
    }

    @Test("a departure the detail view matches reminds the hiker once the dwell is up")
    func departureReachesTheReminder() async throws {
        let (hike, profile) = try await walkingHike()

        let beforeTheDwell = await leaveForADwell(hike, profile: profile)

        #expect(beforeTheDwell.isEmpty, "one fix short of the dwell is not yet a departure")
        #expect(reminders.notifier.postedKinds == [.leftTheTrail])
        #expect(
            SharedStore.load()?.liveFix == nil,
            "the fix that reached the reminder still draws no position on the widget"
        )
    }

    @Test("rejoining takes the reminder down and re-arms it for the next departure")
    func rejoiningRearmsTheReminder() async throws {
        let (hike, profile) = try await walkingHike()
        _ = await leaveForADwell(hike, profile: profile)

        clock.advance(by: Self.fixInterval)
        try follow(hike, profile: profile, onRouteAt: 3)
        await reminders.controller.settle()
        #expect(reminders.notifier.withdrawn.contains(.leftTheTrail))

        _ = await leaveForADwell(hike, profile: profile)
        #expect(reminders.notifier.postedKinds == [.leftTheTrail, .leftTheTrail])
    }
}
}
