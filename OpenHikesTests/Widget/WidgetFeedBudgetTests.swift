//
//  WidgetFeedBudgetTests.swift
//  OpenHikesTests
//
//  `WidgetFeedTests` covers *what* the widget is told. This covers *how
//  often*, and what that costs the main actor — the two things that decide
//  whether the feed is affordable rather than merely correct.
//
//  WidgetKit gives an app a finite number of timeline reloads per day and
//  quietly throttles a widget that overruns it. `publishLiveFix` is fed from a
//  once-a-second poll and defends itself with a 45-second interval, and that
//  interval has an escape hatch — a change in on/off-route status publishes
//  immediately, throttle or not — which is what these tests hold to a bound.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesShared
import SwiftData
import Testing

extension WidgetFeedSuites {
@Suite("Feed budget", .serialized)
final class WidgetFeedBudgetTests {
    private let container: ModelContainer
    private let context: ModelContext
    private let tracker: BackgroundTrailTracker
    /// Its own suite, not the host app's — see ``WidgetFeedTests``.
    private let defaults: UserDefaults

    init() throws {
        container = try Fixture.modelContainer()
        context = ModelContext(container)
        defaults = try makeScratchDefaults()
        tracker = BackgroundTrailTracker(container: container, defaults: defaults)
        SharedStore.clear()
    }

    deinit {
        SharedStore.clear()
    }

    /// A five-hour recording at 1 Hz — the size of track this app is built to
    /// import, and the one that makes every per-point cost visible.
    private static let longRoute: [RouteCoordinate] = (0..<18_000).map { step in
        let t = Double(step)
        return RouteCoordinate(
            latitude: 47.63 + t * 1e-5,
            longitude: 12.86 + t * 5e-6,
            elevation: 600 + 300 * sin(t / 2000),
            timestamp: Date(timeIntervalSince1970: 1_750_000_000 + t)
        )
    }

    private func milliseconds(_ work: () -> Void) -> Double {
        let start = ContinuousClock.now
        work()
        return Double((ContinuousClock.now - start).components.attoseconds) / 1e15
    }

    // MARK: Reload budget

    /// A walker on the edge of the 75 m follow threshold — a ridge path with
    /// trees, a switchback, a phone in a rucksack — flips on/off-route with
    /// ordinary GPS noise. Every flip that takes the escape hatch costs a full
    /// `SharedStore.load`, a re-encode, an atomic write to the App Group, and
    /// a `WidgetCenter.reloadTimelines` call.
    ///
    /// Two things hold that down: `statusFlipInterval` is a floor under the
    /// bypass, and `offRouteExitMeters` widens the threshold for leaving the
    /// trail, so recovering it stays prompt while oscillating around it is not
    /// free.
    @Test("flapping on and off the trail can't spend the whole reload budget")
    func statusFlappingIsBounded() async throws {
        let hike = Fixture.hike(in: context)
        let profile = RouteProfile(route: hike.route)
        tracker.hikeSelectionChanged(to: hike)
        await tracker.waitForSelectionPublish()

        let onRoute = try #require(profile.nearestPoint(to: profile.coordinates[2]))
        let offRoute = try #require(
            profile.nearestPoint(to: CLLocationCoordinate2D(latitude: 37.3350, longitude: -122.0200))
        )
        #expect(
            offRoute.offRouteMeters > RouteProfile.followMatchThresholdMeters,
            "precondition: the second fix reads as off the trail"
        )

        // Twenty polls — twenty seconds of walking, well inside one 45 s window.
        var writes = 0
        var previous = SharedStore.load()?.updatedAt
        for step in 0..<20 {
            tracker.publishLiveFix(
                hike: hike,
                profile: profile,
                match: step.isMultiple(of: 2) ? onRoute : offRoute
            )
            let now = SharedStore.load()?.updatedAt
            if now != previous { writes += 1 }
            previous = now
        }

        #expect(writes <= 2, "one window, at most a first flip and a recovery")
    }

    /// The other half of the fix, and the one that addresses the actual field
    /// scenario: a fix hovering either side of the follow threshold shouldn't
    /// read as a status change at all. Leaving the trail uses a wider distance
    /// than rejoining it, so noise inside that band is not a flip and never
    /// reaches the bypass.
    @Test("noise around the follow threshold isn't a status change")
    func thresholdNoiseIsNotAFlip() async throws {
        let hike = Fixture.hike(in: context)
        let profile = RouteProfile(route: hike.route)
        tracker.hikeSelectionChanged(to: hike)
        await tracker.waitForSelectionPublish()

        let onRoute = try #require(profile.nearestPoint(to: profile.coordinates[2]))
        tracker.publishLiveFix(hike: hike, profile: profile, match: onRoute)

        // Just past the follow threshold, but inside the hysteresis band —
        // the walker has not left the trail.
        let marginal = (
            distanceAlongRoute: onRoute.distanceAlongRoute,
            offRouteMeters: RouteProfile.followMatchThresholdMeters + 1
        )
        var previous = SharedStore.load()?.updatedAt
        var writes = 0
        for _ in 0..<10 {
            tracker.publishLiveFix(hike: hike, profile: profile, match: marginal)
            let now = SharedStore.load()?.updatedAt
            if now != previous { writes += 1 }
            previous = now
        }

        #expect(writes == 0, "a metre past the threshold is noise, not a departure")
        #expect(SharedStore.load()?.liveFix != nil, "and the walker is still shown on the trail")
    }

    /// The behaviour the bypass is there for, which any floor has to keep:
    /// genuinely losing the trail shows up straight away rather than up to 45
    /// seconds later.
    @Test("a first loss of the trail is still published immediately")
    func firstStatusChangeStillBypassesTheThrottle() async throws {
        let hike = Fixture.hike(in: context)
        let profile = RouteProfile(route: hike.route)
        tracker.hikeSelectionChanged(to: hike)
        await tracker.waitForSelectionPublish()

        let onRoute = try #require(profile.nearestPoint(to: profile.coordinates[2]))
        tracker.publishLiveFix(hike: hike, profile: profile, match: onRoute)
        #expect(SharedStore.load()?.liveFix != nil)

        tracker.publishLiveFix(hike: hike, profile: profile, match: nil)
        #expect(SharedStore.load()?.liveFix == nil)
    }

    // MARK: Main-actor cost

    /// Selecting a trail is a tap, and taps are the one place a frame drop is
    /// visible. Only the SwiftData value snapshot belongs on the main actor;
    /// route profiling, decimation, encoding, and the App Group write do not.
    @Test("selecting a long trail doesn't spend a frame on the main actor")
    func selectionStaysInsideAFrame() async {
        let hike = Fixture.hike(in: context, title: "Five hours", route: Self.longRoute)

        let elapsed = milliseconds { tracker.hikeSelectionChanged(to: hike) }
        #expect(elapsed < 4, "selection should only snapshot values and schedule the publication")
        await tracker.waitForSelectionPublish()
        #expect(SharedStore.load()?.hikeID == hike.id, "precondition: it really published")
    }

    /// A deliberately different elevation range makes reuse observable:
    /// rebuilding from the hike would publish the hike's range instead.
    @Test("publishing a fix doesn't rebuild a route profile the caller already has")
    func publishDoesNotRebuildTheProfile() async throws {
        let hike = Fixture.hike(in: context, title: "Five hours", route: Self.longRoute)
        let suppliedRoute = Self.longRoute.map { coordinate in
            RouteCoordinate(
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                elevation: coordinate.elevation.map { $0 + 10_000 },
                timestamp: coordinate.timestamp
            )
        }
        let profile = RouteProfile(route: suppliedRoute)
        #expect(profile.elevation != RouteProfile(route: hike.route).elevation)
        let match = try #require(profile.nearestPoint(to: profile.coordinates[9000]))

        tracker.hikeSelectionChanged(to: hike)
        await tracker.waitForSelectionPublish()
        // A relaunch, or a snapshot the widget's own housekeeping removed:
        // the tracked hike is known but nothing is stored for it.
        SharedStore.clear()

        tracker.publishLiveFix(hike: hike, profile: profile, match: match)

        let snapshot = try #require(SharedStore.load())
        #expect(snapshot.liveFix != nil, "precondition: it really did publish")
        #expect(snapshot.elevationLowMeters == profile.elevation.lowMeters)
        #expect(snapshot.elevationHighMeters == profile.elevation.highMeters)
        #expect(snapshot.elevationGainMeters == profile.elevation.gainMeters)
    }
    }
}
