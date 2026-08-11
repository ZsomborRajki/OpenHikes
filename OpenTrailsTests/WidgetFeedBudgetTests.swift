//
//  WidgetFeedBudgetTests.swift
//  OpenTrailsTests
//
//  `WidgetFeedTests` covers *what* the widget is told. This covers *how
//  often*, and what that costs the main actor — the two things that decide
//  whether the feed is affordable rather than merely correct.
//
//  WidgetKit gives an app a finite number of timeline reloads per day and
//  quietly throttles a widget that overruns it. `publishLiveFix` is fed from a
//  once-a-second poll and defends itself with a 45-second interval, but that
//  interval has an explicit escape hatch — a change in on/off-route status
//  publishes immediately, throttle or not — and nothing bounds how often that
//  escape hatch can fire.
//

import CoreLocation
import Foundation
import OpenTrailsShared
import SwiftData
import Testing
@testable import OpenTrails

@MainActor
@Suite("Widget feed budget", .serialized, .enabled(if: SharedStoreProbe.isAvailable))
final class WidgetFeedBudgetTests {
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
        UserDefaults.standard.removeObject(forKey: "trailTracking.lastMatchedDistance")
    }

    /// A five-hour recording at 1 Hz — the size of track this app is built to
    /// import, and the one that makes every per-point cost visible.
    private static let longRoute: [RouteCoordinate] = (0..<18_000).map { step in
        let t = Double(step)
        return RouteCoordinate(
            latitude: 47.63 + t * 1e-5,
            longitude: 12.86 + t * 5e-6,
            elevation: 600 + 300 * sin(t / 2_000),
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
    /// ordinary GPS noise. Every flip takes the escape hatch: a full
    /// `SharedStore.load`, a re-encode, an atomic write to the App Group, and
    /// a `WidgetCenter.reloadTimelines` call, once a second, indefinitely.
    ///
    /// The throttle exists to stop exactly this, and the status-flip bypass
    /// reopens it. What's missing is a floor — a minimum interval, or
    /// hysteresis on the threshold, so that recovering the trail is prompt but
    /// oscillating around it is not free.
    @Test("flapping on and off the trail can't spend the whole reload budget")
    func statusFlappingIsBounded() throws {
        let hike = Fixture.hike(in: context)
        let profile = RouteProfile(route: hike.route)
        tracker.hikeSelectionChanged(to: hike)

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
    func thresholdNoiseIsNotAFlip() throws {
        let hike = Fixture.hike(in: context)
        let profile = RouteProfile(route: hike.route)
        tracker.hikeSelectionChanged(to: hike)

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
    func firstStatusChangeStillBypassesTheThrottle() throws {
        let hike = Fixture.hike(in: context)
        let profile = RouteProfile(route: hike.route)
        tracker.hikeSelectionChanged(to: hike)

        let onRoute = try #require(profile.nearestPoint(to: profile.coordinates[2]))
        tracker.publishLiveFix(hike: hike, profile: profile, match: onRoute)
        #expect(SharedStore.load()?.liveFix != nil)

        tracker.publishLiveFix(hike: hike, profile: profile, match: nil)
        #expect(SharedStore.load()?.liveFix == nil)
    }

    // MARK: Main-actor cost

    /// Selecting a trail is a tap, and taps are the one place a frame drop is
    /// visible. `hikeSelectionChanged` does all of this on the main actor,
    /// synchronously, before returning to SwiftUI:
    ///
    ///   * `RouteProfile(route:)` — two `CLLocation` allocations per point
    ///     plus a `distance(from:)` call, ~7 ms at 18,000 points;
    ///   * `hike.coordinates` — a second full pass over the route;
    ///   * `decimate(_:)` — a third;
    ///   * `JSONEncoder` over the decimated polyline; and
    ///   * an atomic write into the App Group container — real disk I/O, the
    ///     exact thing `MainThreadWatchdog` exists to catch.
    ///
    /// Measured on the Simulator at 18,000 points: ~11 ms, most of one frame,
    /// for a hike the app is explicitly designed to import. None of it needs
    /// to be on the main actor: the only main-actor-bound part is reading the
    /// `Hike`, and `TileOwnership` already demonstrates the snapshot-then-hop
    /// pattern that would move the rest off.
    @Test("selecting a long trail doesn't spend a frame on the main actor")
    func selectionStaysInsideAFrame() throws {
        let hike = Fixture.hike(title: "Five hours", route: Self.longRoute, in: context)

        let elapsed = milliseconds { tracker.hikeSelectionChanged(to: hike) }
        #expect(SharedStore.load()?.hikeID == hike.id, "precondition: it really published")

        withKnownIssue("profile build, two route passes, JSON encoding and an App Group write all run on the main actor") {
            #expect(elapsed < 4, "a quarter of a 60 Hz frame; measured 8–11 ms at 18,000 points")
        }
    }

    /// The same work again, from the caller that already did it.
    /// `updateStoredLiveFix` rebuilds the whole snapshot — and with it a
    /// `RouteProfile` — whenever nothing is stored for the hike being
    /// published, discarding the profile its caller is holding.
    ///
    /// `handleBackgroundFix` makes the waste explicit: it builds a profile,
    /// matches the fix against it, and then hands the hike (not the profile)
    /// to `updateStoredLiveFix`, which builds a second one. That's two O(n)
    /// passes with two `CLLocation` allocations per point, on the main actor,
    /// per background fix — and the background path is precisely the one that
    /// runs on a relaunch, where nothing is stored yet.
    @Test("publishing a fix doesn't rebuild a route profile the caller already has")
    func publishDoesNotRebuildTheProfile() throws {
        let hike = Fixture.hike(title: "Five hours", route: Self.longRoute, in: context)
        let profile = RouteProfile(route: hike.route)
        let match = try #require(profile.nearestPoint(to: profile.coordinates[9_000]))

        tracker.hikeSelectionChanged(to: hike)
        // A relaunch, or a snapshot the widget's own housekeeping removed:
        // the tracked hike is known but nothing is stored for it.
        SharedStore.clear()

        let elapsed = milliseconds {
            tracker.publishLiveFix(hike: hike, profile: profile, match: match)
        }
        #expect(SharedStore.load()?.liveFix != nil, "precondition: it really did publish")

        withKnownIssue("updateStoredLiveFix rebuilds the snapshot, and its profile, from the hike") {
            #expect(
                elapsed < 3,
                "the caller passed the profile in; publishing a position shouldn't build another"
            )
        }
    }
}
