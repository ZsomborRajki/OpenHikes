//
//  TrailWalkEndBoundaryTests.swift
//  OpenHikesTests
//
//  That an ended walk's result keeps the Lock Screen to itself.
//
//  `TrailWalkActivityTests` asserts that ending a walk leaves its closing
//  figures up for `finishedDismissAfter`. This asserts the other half of that
//  promise: for as long as the boundary stands, nothing the walker's own
//  receiver keeps producing may put a second panel beside that result or
//  replace it. The fixes do not stop when the walk does — a walker who taps
//  End is still standing on the route, and a background match may already have
//  been in flight when the terminal write landed — and every one of them
//  carries no walk, which is exactly what an ordinary plain follow looks like.
//
//  The boundary is the session's, not this file's: it is cleared by leaving
//  the route or by asking to follow the trail again, and the last test here is
//  what keeps this from being a rule that never lets go.
//
//  Hosted by the same App Group probe the other feed suites are, and its own
//  class rather than an extension of `TrailWalkActivityTests` because these
//  need a clock the tracker reads too — the foreground feed's 45-second
//  throttle is what a second fix has to clear — and a significant-change
//  monitor the walk suite has no use for.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesShared
import SwiftData
import Testing

extension WidgetFeedSuites {
@Suite("Trail walk end boundary", .serialized)
final class TrailWalkEndBoundaryTests {
    /// A minute between matched fixes: past the foreground feed's 45-second
    /// throttle, so every fix a test hands over is one that really publishes.
    /// Named because `no_magic_numbers` skips a `@Test` body and these are
    /// helpers.
    private static let fixInterval: TimeInterval = 60
    /// The pause between the last match and the End, so the two are not the
    /// same instant on a clock that only moves when a test says so.
    private static let endDelay: TimeInterval = 1
    /// A receiver good enough to match against the route, the way
    /// `BackgroundDeliveryTests` states one.
    private static let fixAccuracy: CLLocationAccuracy = 10

    private let container: ModelContainer
    private let context: ModelContext
    private let clock: TestClock
    private let monitor: StubLocationMonitor
    private let tracker: BackgroundTrailTracker
    private let controller: HikeLiveActivityController
    private let presenter: StubHikeActivityPresenter
    private let session: TrailWalkSession
    private let defaults: UserDefaults

    init() throws {
        clock = TestClock()
        monitor = StubLocationMonitor()
        container = try Fixture.modelContainer()
        context = ModelContext(container)
        defaults = try makeScratchDefaults()
        defaults.set(true, forKey: SettingsKey.liveActivitiesEnabled)
        presenter = StubHikeActivityPresenter()
        controller = HikeLiveActivityController(
            presenter: presenter,
            defaults: defaults,
            clock: clock.read
        )
        tracker = BackgroundTrailTracker(
            container: container,
            monitor: monitor,
            defaults: defaults,
            liveActivityController: controller,
            clock: clock.read
        )
        session = TrailWalkSession(context: context, tracker: tracker, clock: clock.read)
        SharedStore.clear()
    }

    deinit {
        SharedStore.clear()
    }

    /// A trail selected and published, which is where following one begins.
    /// Saved as well, because the background feed matches against the store
    /// rather than against anything held in memory.
    private func selectedHike() async throws -> Hike {
        let hike = Fixture.hike(in: context)
        try context.save()
        tracker.hikeSelectionChanged(to: hike)
        await tracker.waitForSelectionPublish()
        return hike
    }

    /// One matched fix, along the path `HikeDetailView`'s follow loop takes:
    /// feed the session, then publish the fix unless it was the one that
    /// closed the walk.
    ///
    /// - Returns: whether this fix completed the walk.
    @discardableResult private func match(_ hike: Hike, profile: RouteProfile, at index: Int) async throws -> Bool {
        clock.advance(by: Self.fixInterval)
        let completed = session.recordForegroundMatch(
            hike: hike,
            profile: profile,
            distance: profile.distances[index]
        )
        if !completed, session.publishes(hikeID: hike.id) {
            let point = try #require(profile.nearestPoint(to: profile.coordinates[index]))
            tracker.publishLiveFix(
                hike: hike,
                profile: profile,
                match: point,
                walk: session.payload(for: hike.id)
            )
        }
        await tracker.waitForLiveFixPublish()
        await controller.settle()
        return completed
    }

    /// Starts a walk and gets it far enough along to be worth keeping.
    private func startWalk(_ hike: Hike, profile: RouteProfile) async throws {
        for index in 0...2 {
            try await match(hike, profile: profile, at: index)
        }
    }

    /// A significant-change fix, delivered through the delegate the way
    /// CoreLocation delivers one, and waited out.
    private func deliverBackgroundFix(at coordinate: CLLocationCoordinate2D) async {
        monitor.deliver(
            CLLocation(
                coordinate: coordinate,
                altitude: 0,
                horizontalAccuracy: Self.fixAccuracy,
                verticalAccuracy: -1,
                course: -1,
                speed: -1,
                timestamp: Date()
            )
        )
        await tracker.waitForLiveFixPublish()
        await controller.settle()
    }

    /// End is not the last fix. The walker who taps it is still standing on
    /// the trail, and the next accepted fix along it carries no walk — so
    /// without the boundary it reads as a plain follow and ActivityKit is
    /// asked for a second panel while the finished one is still deliberately
    /// on screen.
    @Test("a fix after End starts no second activity")
    func fixAfterEndStartsNothing() async throws {
        let hike = try await selectedHike()
        let profile = RouteProfile(route: hike.route)
        try await startWalk(hike, profile: profile)

        clock.advance(by: Self.endDelay)
        session.end()
        await tracker.waitForLiveFixPublish()
        await controller.settle()
        let afterEnding = presenter.calls.count

        try await match(hike, profile: profile, at: 3)

        #expect(presenter.calls.count == afterEnding, "the result keeps the Lock Screen to itself")
        #expect(presenter.startedSubjects == [.following(hikeID: hike.id)], "the walk's own start, and no other")
        #expect(controller.activeSubject == nil)
        #expect(SharedStore.load()?.liveFix != nil, "though the widget still got the fix")
        #expect(SharedStore.load()?.walk == nil, "as an ordinary follow, which is what it is")
    }

    /// The same boundary, reached the other way. A walk that completes at the
    /// route's end has no End tap behind it, and the walker stands at the
    /// finish for as long as it takes to read the result — which is a run of
    /// on-route fixes, not one.
    @Test("the fixes after a completed walk start no second activity")
    func fixesAfterCompletionStartNothing() async throws {
        let hike = try await selectedHike()
        let profile = RouteProfile(route: hike.route)
        let last = profile.coordinates.count - 1
        for index in 0..<last {
            try await match(hike, profile: profile, at: index)
        }

        let completed = try await match(hike, profile: profile, at: last)
        #expect(completed, "precondition: the route's end closes the walk on its own")
        #expect(session.lastEndedWalk?.endReason == .reachedEnd)
        let afterEnding = presenter.calls.count

        // Still at the finish, two fixes later.
        try await match(hike, profile: profile, at: last)
        try await match(hike, profile: profile, at: last)

        #expect(presenter.calls.count == afterEnding, "nothing was asked of ActivityKit")
        #expect(presenter.startedSubjects == [.following(hikeID: hike.id)], "the walk's own start, and no other")
        #expect(controller.activeSubject == nil)
    }

    /// A background match already under way when End lands is the one that
    /// cannot be suppressed at its source: it was started before there was
    /// anything to suppress, and it finishes against a session whose walk is
    /// already gone.
    @Test("a background fix arriving after End starts no second activity")
    func backgroundFixAfterEndStartsNothing() async throws {
        let hike = try await selectedHike()
        let profile = RouteProfile(route: hike.route)
        try await startWalk(hike, profile: profile)

        clock.advance(by: Self.endDelay)
        session.end()
        await tracker.waitForLiveFixPublish()
        await controller.settle()
        let afterEnding = presenter.calls.count

        await deliverBackgroundFix(at: profile.coordinates[3])

        #expect(presenter.calls.count == afterEnding, "nothing was asked of ActivityKit")
        #expect(presenter.startedSubjects == [.following(hikeID: hike.id)], "the walk's own start, and no other")
        #expect(controller.activeSubject == nil)
        #expect(SharedStore.load()?.liveFix != nil, "precondition: the fix was matched and published")
    }

    /// And the boundary lets go. Leaving the route is the walker saying they
    /// are done with this trail, so coming back to it is a walk of its own —
    /// with an activity of its own, which is the whole point of not suppressing
    /// these for good.
    @Test("a rearmed hike starts a new activity")
    func rearmedHikeStartsANewActivity() async throws {
        let hike = try await selectedHike()
        let profile = RouteProfile(route: hike.route)
        try await startWalk(hike, profile: profile)

        clock.advance(by: Self.endDelay)
        session.end()
        await tracker.waitForLiveFixPublish()
        await controller.settle()

        // Off the trail, the way the follow loop reports it: the session is
        // rearmed and the widget told there is no fix to show.
        clock.advance(by: Self.fixInterval)
        session.recordOffRoute(hikeID: hike.id)
        tracker.publishLiveFix(hike: hike, profile: profile, match: nil, walk: nil)
        await tracker.waitForLiveFixPublish()
        await controller.settle()
        #expect(controller.activeSubject == nil, "and leaving alone starts nothing")

        try await match(hike, profile: profile, at: 4)

        #expect(session.walkedHikeID == hike.id, "back on the trail is a new walk")
        #expect(
            presenter.startedSubjects == [.following(hikeID: hike.id), .following(hikeID: hike.id)],
            "which gets a panel of its own"
        )
        #expect(controller.activeSubject == .following(hikeID: hike.id))
    }

}
}
