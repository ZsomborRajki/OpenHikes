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

    /// Somewhere in the middle of it, so a match has the whole route either
    /// side of it to search.
    private static let midpointIndex = longRoute.count / 2

    private func milliseconds(_ work: () -> Void) -> Double {
        let start = ContinuousClock.now
        work()
        return Double((ContinuousClock.now - start).components.attoseconds) / 1e15
    }

    /// The budget every measurement here is held to: the cost of profiling the
    /// same route once, measured on the machine running the test.
    ///
    /// Relative rather than a fixed number of milliseconds, because an
    /// absolute figure is a statement about the host and not about the app.
    /// This started as `elapsed < 5`, which held on a developer's machine and
    /// went red on CI at 5.9 ms and again under ThreadSanitizer at 5.8 ms —
    /// having moved nothing back onto the main actor. A shared runner is
    /// several times slower, and a sanitizer that instruments every memory
    /// access slower again. `PERFORMANCE.md` reaches the same conclusion about
    /// footprints measured under XCUITest: only compare within a run.
    ///
    /// A rebuild is the yardstick because it is the route-sized work these
    /// paths exist to keep off the frame, and it is charged to the same host
    /// and the same instrumentation as the measurement beside it. Measured on
    /// a quiet machine: 0.4–1.4 ms of main-actor work against a 6.4 ms
    /// rebuild, inside a 9.0 ms selection pipeline.
    ///
    /// These stopwatches are the second line rather than the first. Running
    /// the *delegated* work on the main actor trips `assertOffMainThread`,
    /// and ``offMainSeamLeavesTheMainThread`` pins the hop itself. What only a
    /// stopwatch catches is route-sized work done synchronously *before* that
    /// hop, which no assertion is placed on: calling `buildSnapshot` inline in
    /// `hikeSelectionChanged` measured 8.0 ms against a 6.2 ms budget, and
    /// matching a background fix inline measured 36.3 ms against 6.2 ms.
    ///
    /// The best of three rather than one sample: a hiccup landing in the
    /// sample that sets the budget would raise it, and this is the side that
    /// must not be generous.
    private func routeRebuildMilliseconds() -> Double {
        (0..<3)
            .map { _ in milliseconds { _ = RouteProfile(route: Self.longRoute) } }
            .min() ?? .infinity
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
            await tracker.waitForLiveFixPublish()
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
        await tracker.waitForLiveFixPublish()

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
            await tracker.waitForLiveFixPublish()
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
        await tracker.waitForLiveFixPublish()
        #expect(SharedStore.load()?.liveFix != nil)

        tracker.publishLiveFix(hike: hike, profile: profile, match: nil)
        await tracker.waitForLiveFixPublish()
        #expect(SharedStore.load()?.liveFix == nil)
    }

    // MARK: Main-actor cost

    /// Selecting a trail is a tap, and taps are the one place a frame drop is
    /// visible. Only the SwiftData value snapshot belongs on the main actor;
    /// route profiling, decimation, encoding, and the App Group write do not.
    @Test("selecting a long trail doesn't spend a frame on the main actor")
    func selectionStaysInsideAFrame() async {
        let hike = Fixture.hike(in: context, title: "Five hours", route: Self.longRoute)

        let budget = routeRebuildMilliseconds()
        let elapsed = milliseconds { tracker.hikeSelectionChanged(to: hike) }
        #expect(
            elapsed < budget,
            """
            selection should only snapshot values and schedule the publication: \
            \(elapsed) ms against a \(budget) ms route rebuild
            """
        )
        await tracker.waitForSelectionPublish()
        #expect(SharedStore.load()?.hikeID == hike.id, "precondition: it really published")
    }

    /// The same claim for the live-fix feed, which had been left behind: the
    /// write path read the App Group file, rebuilt and decimated the trail when
    /// the store held a different one, encoded the result and wrote it back —
    /// all synchronously, on the actor that draws.
    ///
    /// The rebuild is provoked deliberately by clearing the store after
    /// selection, because that is the expensive branch and the one a relaunch
    /// takes. A fix landing on a trail already stored only re-encodes.
    @Test("publishing a fix onto a trail the store doesn't hold stays inside a frame")
    func publishingRebuildStaysInsideAFrame() async throws {
        let hike = Fixture.hike(in: context, title: "Five hours", route: Self.longRoute)
        let profile = RouteProfile(route: hike.route)
        let match = try #require(profile.nearestPoint(to: profile.coordinates[Self.midpointIndex]))
        tracker.hikeSelectionChanged(to: hike)
        await tracker.waitForSelectionPublish()
        // A relaunch, or a snapshot the widget's own housekeeping removed: the
        // tracked hike is known but nothing is stored for it.
        SharedStore.clear()

        let budget = routeRebuildMilliseconds()
        let elapsed = milliseconds { tracker.publishLiveFix(hike: hike, profile: profile, match: match) }

        await tracker.waitForLiveFixPublish()
        #expect(SharedStore.load()?.liveFix != nil, "precondition: it really did publish")
        #expect(
            elapsed < budget,
            """
            the load, the rebuild, the encode and the App Group write all belong off the main actor: \
            \(elapsed) ms against a \(budget) ms route rebuild
            """
        )
    }

    /// And for the background feed, which is the expensive one. A
    /// significant-change wake-up has no profile in memory, so the fix is
    /// matched against a route read back from SwiftData and rebuilt from
    /// scratch — a route-sized materialisation and then two O(route points)
    /// passes, before the write path is even reached.
    ///
    /// This is a guard rather than a benchmark, and it is worth saying what it
    /// guards: `BackgroundTrailTracker` declares no isolation, and
    /// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` makes everything on it
    /// main-actor by default. Work put here is main-thread work unless
    /// something deliberately moves it, and nothing about the call site says
    /// so.
    @Test("matching a background fix against a long route stays inside a frame")
    func backgroundFixStaysInsideAFrame() async throws {
        let hike = Fixture.hike(in: context, title: "Five hours", route: Self.longRoute)
        try context.save()
        defaults.set(hike.id.uuidString, forKey: SettingsKey.lastSelectedHikeID)
        let monitor = StubLocationMonitor()
        // Retained for the length of the test: the monitor holds its delegate
        // weakly, exactly as CoreLocation does.
        let relaunched = BackgroundTrailTracker(container: container, monitor: monitor, defaults: defaults)
        let profile = RouteProfile(route: hike.route)
        let location = CLLocation(
            coordinate: profile.coordinates[Self.midpointIndex],
            altitude: 0,
            horizontalAccuracy: 10,
            verticalAccuracy: -1,
            course: -1,
            speed: -1,
            timestamp: .now
        )

        let budget = routeRebuildMilliseconds()
        let elapsed = milliseconds { monitor.deliver(location) }

        await relaunched.waitForLiveFixPublish()
        #expect(SharedStore.load()?.liveFix != nil, "precondition: it really did publish")
        #expect(
            elapsed < budget,
            """
            the delegate callback should judge the fix and schedule, not read and profile 18,000 points: \
            \(elapsed) ms against a \(budget) ms route rebuild
            """
        )
    }

    /// The guarantee the three budgets above rest on, asserted directly rather
    /// than through a stopwatch — and asserted the way
    /// `CloudSyncCoordinatorTests` asserts its own seam, because it is the same
    /// mistake: a `Task {}` started from a method on a `@MainActor` type looks
    /// exactly like `Task.detached` and runs its body on the main thread.
    /// Stripping `@concurrent` or `nonisolated` from the seam fails here
    /// immediately, with the reason, instead of showing up as a slow frame in
    /// the field.
    @Test("the widget feed's hop off the main actor really leaves the main thread")
    func offMainSeamLeavesTheMainThread() async {
        // `pthread_main_np` rather than `Thread.isMainThread`, which Swift
        // makes unavailable from an `async` context — the very context the
        // question has to be asked in.
        #expect(pthread_main_np() != 0, "the bug needs a main-actor caller to reproduce")

        let ranOnMainThread = await BackgroundTrailTracker.offMainThread { pthread_main_np() != 0 }

        #expect(!ranOnMainThread)
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
        await tracker.waitForLiveFixPublish()

        let snapshot = try #require(SharedStore.load())
        #expect(snapshot.liveFix != nil, "precondition: it really did publish")
        #expect(snapshot.elevationLowMeters == profile.elevation.lowMeters)
        #expect(snapshot.elevationHighMeters == profile.elevation.highMeters)
        #expect(snapshot.elevationGainMeters == profile.elevation.gainMeters)
    }
    }
}
