//
//  WidgetFeedTests.swift
//  OpenHikesTests
//
//  The Home Screen widget never computes anything: it draws a precomputed
//  snapshot the app writes into the App Group. So everything the user sees
//  there is decided here — which trail, how far along
//  it, and whether that reading is fresh enough to show at all.
//
//  The throttle is part of the contract, not an implementation detail: the
//  live-fix feed is fed from a once-a-second poll, and a widget that asks to
//  be reloaded every second gets its reload budget cut by the system.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesShared
import SwiftData
import Testing

/// Both child suites share one App Group file, so they must not run beside
/// each other even when they are selected together.
@Suite("Widget feeds", .serialized, .enabled(if: SharedStoreProbe.isAvailable))
struct WidgetFeedSuites {}

extension WidgetFeedSuites {
@Suite("Feed behavior", .serialized)
final class WidgetFeedTests {
    private let container: ModelContainer
    private let context: ModelContext
    private let tracker: BackgroundTrailTracker

    init() throws {
        container = try Fixture.modelContainer()
        context = ModelContext(container)
        tracker = BackgroundTrailTracker(container: container)
        SharedStore.clear()
    }

    deinit {
        SharedStore.clear()
        UserDefaults.standard.removeObject(forKey: SettingsKey.lastMatchedDistance)
    }

    private func hike() -> Hike {
        Fixture.hike(in: context)
    }

    // MARK: Selection

    /// Selecting a trail publishes its shape immediately, before any fix
    /// arrives — otherwise the widget would sit on the previous trail (or
    /// empty) until the user next moved.
    @Test("selecting a hike publishes everything the widget draws")
    func selectionPublishesSnapshot() async throws {
        let hike = hike()
        tracker.hikeSelectionChanged(to: hike)
        await tracker.waitForSelectionPublish()

        let snapshot = try #require(SharedStore.load())
        #expect(snapshot.hikeID == hike.id)
        #expect(snapshot.title == hike.title)
        #expect(snapshot.tintHex == hike.tintHex)
        #expect(snapshot.totalDistanceMeters == hike.distanceMeters)
        #expect(snapshot.liveFix == nil, "a fresh selection has no position yet")

        // The drawn line has to be the trail: same endpoints, same order.
        let first = try #require(snapshot.polyline.first)
        let last = try #require(snapshot.polyline.last)
        #expect(abs(first.latitude - Fixture.ridgeRoute[0].latitude) < 1e-9)
        #expect(abs(last.latitude - (Fixture.ridgeRoute.last?.latitude ?? 0)) < 1e-9)
        #expect(snapshot.polyline.count == Fixture.ridgeRoute.count)

        #expect(snapshot.elevationLowMeters == 100)
        #expect(snapshot.elevationHighMeters == 260)
    }

    @Test("deselecting clears the trail rather than leaving a stale one")
    func deselectionClears() async {
        tracker.hikeSelectionChanged(to: hike())
        await tracker.waitForSelectionPublish()
        #expect(SharedStore.load() != nil)
        tracker.hikeSelectionChanged(to: nil)
        await tracker.waitForSelectionPublish()
        #expect(SharedStore.load() == nil)
    }

    /// A hike with a single point has no shape to draw.
    @Test("a hike with nothing to draw clears the widget")
    func degenerateHikeClears() async {
        tracker.hikeSelectionChanged(to: hike())
        await tracker.waitForSelectionPublish()
        let stub = Fixture.hike(in: context, route: [RouteCoordinate(latitude: 47.63, longitude: 12.86)])
        tracker.hikeSelectionChanged(to: stub)
        await tracker.waitForSelectionPublish()
        #expect(SharedStore.load() == nil)
    }

    // MARK: The live fix

    @Test("an on-route fix is published as progress along the trail")
    func liveFixPublished() async throws {
        let hike = hike()
        let profile = RouteProfile(route: hike.route)
        tracker.hikeSelectionChanged(to: hike)
        await tracker.waitForSelectionPublish()

        let match = try #require(profile.nearestPoint(to: profile.coordinates[3]))
        tracker.publishLiveFix(hike: hike, profile: profile, match: match)

        let snapshot = try #require(SharedStore.load())
        let fix = try #require(snapshot.liveFix)
        #expect(abs(fix.distanceAlongRouteMeters - profile.distances[3]) < 1)
        #expect(fix.offRouteMeters < RouteProfile.followMatchThresholdMeters)

        let fraction = try #require(snapshot.fractionComplete)
        #expect(fraction > 0 && fraction < 1)
        #expect(snapshot.statusText.contains("%"))
        let remaining = try #require(snapshot.remainingDistanceMeters)
        #expect(abs(remaining - (hike.distanceMeters - fix.distanceAlongRouteMeters)) < 1)
    }

    /// A fix too far from the trail isn't progress — the widget shows the
    /// trail's length instead of a made-up position.
    @Test("a fix off the trail publishes no position")
    func offRouteFixPublishesNothing() async throws {
        let hike = hike()
        let profile = RouteProfile(route: hike.route)
        tracker.hikeSelectionChanged(to: hike)
        await tracker.waitForSelectionPublish()

        let far = try #require(
            profile.nearestPoint(to: CLLocationCoordinate2D(latitude: 37.3350, longitude: -122.0200))
        )
        #expect(far.offRouteMeters > RouteProfile.followMatchThresholdMeters, "precondition: this fix is off the trail")
        tracker.publishLiveFix(hike: hike, profile: profile, match: far)

        let snapshot = try #require(SharedStore.load())
        #expect(snapshot.liveFix == nil)
        #expect(!snapshot.statusText.contains("%"))
    }

    /// The poll runs once a second; the feed must not.
    @Test("a second fix moments later doesn't republish")
    func publishesAreThrottled() async throws {
        let hike = hike()
        let profile = RouteProfile(route: hike.route)
        tracker.hikeSelectionChanged(to: hike)
        await tracker.waitForSelectionPublish()

        let first = try #require(profile.nearestPoint(to: profile.coordinates[1]))
        tracker.publishLiveFix(hike: hike, profile: profile, match: first)
        let published = try #require(SharedStore.load()?.liveFix)

        let later = try #require(profile.nearestPoint(to: profile.coordinates[4]))
        tracker.publishLiveFix(hike: hike, profile: profile, match: later)
        let stillPublished = try #require(SharedStore.load()?.liveFix)
        #expect(stillPublished.distanceAlongRouteMeters == published.distanceAlongRouteMeters)
    }

    /// …except when the answer to "are you on the trail?" changes, which is
    /// the one update worth spending a reload on immediately.
    @Test("losing the trail is published immediately, throttle or not")
    func statusFlipBypassesTheThrottle() async throws {
        let hike = hike()
        let profile = RouteProfile(route: hike.route)
        tracker.hikeSelectionChanged(to: hike)
        await tracker.waitForSelectionPublish()

        let onRoute = try #require(profile.nearestPoint(to: profile.coordinates[1]))
        tracker.publishLiveFix(hike: hike, profile: profile, match: onRoute)
        #expect(SharedStore.load()?.liveFix != nil)

        tracker.publishLiveFix(hike: hike, profile: profile, match: nil)
        #expect(SharedStore.load()?.liveFix == nil, "walking off the trail should show right away")
    }

    /// The detail view of a hike that isn't the selected one can still be
    /// polling; its fixes must not overwrite the tracked trail.
    @Test("a fix for a hike that isn't the tracked one is ignored")
    func ignoresUntrackedHikes() async throws {
        let tracked = hike()
        let other = Fixture.hike(in: context, title: "Elsewhere")
        tracker.hikeSelectionChanged(to: tracked)
        await tracker.waitForSelectionPublish()

        let profile = RouteProfile(route: other.route)
        let match = try #require(profile.nearestPoint(to: profile.coordinates[2]))
        tracker.publishLiveFix(hike: other, profile: profile, match: match)

        let snapshot = try #require(SharedStore.load())
        #expect(snapshot.hikeID == tracked.id)
        #expect(snapshot.liveFix == nil)
    }

    /// Changing trails has to reset the throttle and the position, or the
    /// new trail inherits the old one's progress.
    @Test("switching trails starts the new one from scratch")
    func switchingTrailsResets() async throws {
        let first = hike()
        let profile = RouteProfile(route: first.route)
        tracker.hikeSelectionChanged(to: first)
        await tracker.waitForSelectionPublish()
        let match = try #require(profile.nearestPoint(to: profile.coordinates[3]))
        tracker.publishLiveFix(hike: first, profile: profile, match: match)
        #expect(SharedStore.load()?.liveFix != nil)

        let second = Fixture.hike(in: context, title: "Second")
        tracker.hikeSelectionChanged(to: second)
        await tracker.waitForSelectionPublish()
        let snapshot = try #require(SharedStore.load())
        #expect(snapshot.hikeID == second.id)
        #expect(snapshot.liveFix == nil)
    }

    @Test("rapid selection changes publish only the latest trail")
    func rapidSelectionPublishesLatest() async throws {
        let first = hike()
        let second = Fixture.hike(in: context, title: "Second", route: Fixture.loopRoute)

        tracker.hikeSelectionChanged(to: first)
        tracker.hikeSelectionChanged(to: second)
        await tracker.waitForSelectionPublish()

        #expect(try #require(SharedStore.load()).hikeID == second.id)
    }

    @Test("deselecting while a publish is pending can't restore a stale trail")
    func pendingPublishCannotOutliveDeselection() async {
        tracker.hikeSelectionChanged(to: hike())
        tracker.hikeSelectionChanged(to: nil)
        await tracker.waitForSelectionPublish()

        #expect(SharedStore.load() == nil)
    }
}
}
