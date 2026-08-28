//
//  TrailFollowActivityTests.swift
//  OpenHikesTests
//
//  That following an imported trail reaches the Lock Screen, and leaves it.
//
//  The counterpart to `HikeRecorderTests+LiveActivity`, and the same division:
//  the policy is `HikeLiveActivityControllerTests`, and what is asserted here
//  is that ``BackgroundTrailTracker`` is wired to it correctly — including the
//  two rules that are specific to a follow rather than a recording. An
//  activity must not appear merely because a walker opened a trail to look at
//  it, and it must come down when they stop following, because nothing else
//  would ever take it down.
//
//  Hosted by the same App Group probe the widget feed suites are: the activity
//  is published from the write path, so a machine with no provisioned
//  container has nothing to observe.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesShared
import SwiftData
import Testing

extension WidgetFeedSuites {
@Suite("Trail follow Live Activity", .serialized)
final class TrailFollowActivityTests {
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

    /// Selecting a trail publishes its whole shape to the widget. It must not
    /// put anything on the Lock Screen: browsing is not following, and an
    /// activity for every trail a walker taps would be the app talking over
    /// them.
    @Test("selecting a trail alone starts no activity")
    func selectionAloneStartsNothing() async {
        tracker.hikeSelectionChanged(to: hike())
        await tracker.waitForSelectionPublish()
        #expect(presenter.calls.isEmpty)
        #expect(controller.activeSubject == nil)
    }

    @Test("a matched fix puts the trail on the Lock Screen")
    func matchedFixStartsAnActivity() async throws {
        let hike = hike()
        let profile = RouteProfile(route: hike.route)
        tracker.hikeSelectionChanged(to: hike)
        await tracker.waitForSelectionPublish()

        let match = try #require(profile.nearestPoint(to: profile.coordinates[3]))
        tracker.publishLiveFix(hike: hike, profile: profile, match: match)
        await tracker.waitForLiveFixPublish()
        await controller.settle()

        #expect(presenter.startedSubjects == [.following(hikeID: hike.id)])
        let state = try #require(presenter.startedStates.first)
        #expect(abs(state.distanceMeters - profile.distances[3]) < 1)
        #expect(state.offRouteMeters != nil)
    }

    /// The activity's numbers are the widget's, taken from the same snapshot
    /// the store just received — which is the whole reason the hook sits on
    /// the write path rather than beside it.
    @Test("the activity and the widget read the same snapshot")
    func activityMatchesTheStoredSnapshot() async throws {
        let hike = hike()
        let profile = RouteProfile(route: hike.route)
        tracker.hikeSelectionChanged(to: hike)
        await tracker.waitForSelectionPublish()

        let match = try #require(profile.nearestPoint(to: profile.coordinates[3]))
        tracker.publishLiveFix(hike: hike, profile: profile, match: match)
        await tracker.waitForLiveFixPublish()
        await controller.settle()

        let snapshot = try #require(SharedStore.load())
        let stored = HikeActivityAttributes.ContentState(following: snapshot)
        #expect(presenter.startedStates.first == stored)
    }

    /// Switching trails ends the old activity rather than relabelling it:
    /// ActivityKit cannot deliver new attributes, and the title is one.
    @Test("changing the selection takes the activity down")
    func changingSelectionEndsTheActivity() async throws {
        let hike = hike()
        let profile = RouteProfile(route: hike.route)
        tracker.hikeSelectionChanged(to: hike)
        await tracker.waitForSelectionPublish()
        let match = try #require(profile.nearestPoint(to: profile.coordinates[3]))
        tracker.publishLiveFix(hike: hike, profile: profile, match: match)
        await tracker.waitForLiveFixPublish()
        await controller.settle()
        #expect(controller.activeSubject != nil)

        let other = Fixture.hike(in: context, title: "Second", route: Fixture.loopRoute)
        tracker.hikeSelectionChanged(to: other)
        await tracker.waitForSelectionPublish()
        await controller.settle()
        #expect(controller.activeSubject == nil)
        #expect(presenter.endCount == 1)
    }

    /// Clearing the selection is the same statement, and reaches the same
    /// place. Asserted separately because `nil` took a different branch
    /// through `hikeSelectionChanged` before this hook existed.
    @Test("clearing the selection takes the activity down")
    func clearingSelectionEndsTheActivity() async throws {
        let hike = hike()
        let profile = RouteProfile(route: hike.route)
        tracker.hikeSelectionChanged(to: hike)
        await tracker.waitForSelectionPublish()
        let match = try #require(profile.nearestPoint(to: profile.coordinates[3]))
        tracker.publishLiveFix(hike: hike, profile: profile, match: match)
        await tracker.waitForLiveFixPublish()
        await controller.settle()

        tracker.hikeSelectionChanged(to: nil)
        await tracker.waitForSelectionPublish()
        await controller.settle()
        #expect(controller.activeSubject == nil)
    }

    /// Turning auto-follow off stops the foreground feed, so an activity left
    /// running would report the walker's last known position for as long as
    /// the app lived. `HikeDetailView` calls this; the assertion is that the
    /// tracker honours it.
    @Test("ending the follow explicitly takes the activity down")
    func endingTheFollowRemovesTheActivity() async throws {
        let hike = hike()
        let profile = RouteProfile(route: hike.route)
        tracker.hikeSelectionChanged(to: hike)
        await tracker.waitForSelectionPublish()
        let match = try #require(profile.nearestPoint(to: profile.coordinates[3]))
        tracker.publishLiveFix(hike: hike, profile: profile, match: match)
        await tracker.waitForLiveFixPublish()
        await controller.settle()

        tracker.endFollowActivity(hikeID: hike.id)
        await controller.settle()
        #expect(controller.activeSubject == nil)
        #expect(
            presenter.calls.last == .end(finalState: nil, dismissAfter: nil)
        )
    }

    /// A follow ending must never take a recording's activity with it — and
    /// both are ended from paths that fire regardless of which one holds the
    /// screen.
    @Test("ending the follow leaves a recording's activity alone")
    func endingTheFollowSparesARecording() async {
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

        tracker.endFollowActivity(hikeID: nil)
        await controller.settle()
        #expect(controller.activeSubject == .recording(sessionID: sessionID))
        #expect(presenter.endCount == 0)
    }

    /// A tracker built without a controller has to behave exactly as it did
    /// before the feature existed.
    @Test("a tracker with no controller publishes normally")
    func trackerWithoutAControllerIsUnaffected() async throws {
        let plain = BackgroundTrailTracker(
            container: container,
            defaults: try makeScratchDefaults()
        )
        let hike = hike()
        let profile = RouteProfile(route: hike.route)
        plain.hikeSelectionChanged(to: hike)
        await plain.waitForSelectionPublish()
        let match = try #require(profile.nearestPoint(to: profile.coordinates[3]))
        plain.publishLiveFix(hike: hike, profile: profile, match: match)
        await plain.waitForLiveFixPublish()

        #expect(SharedStore.load()?.liveFix != nil)
        #expect(presenter.calls.isEmpty)
    }
}
}
