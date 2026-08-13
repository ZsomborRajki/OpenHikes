//
//  BackgroundTrackingTests.swift
//  OpenTrailsTests
//
//  The background-relaunch path: the app is woken by a significant location
//  change with no in-memory state at all, and everything it then does is
//  decided by three things it reads from outside itself — whether Always
//  authorization is granted, which hike `UserDefaults` says was selected, and
//  a fix delivered through a `CLLocationManagerDelegate` callback.
//
//  All three are now injected (`SignificantLocationMonitor`, a `UserDefaults`
//  suite, a clock), which is what makes any of this reachable from a test.
//  Before that, the only way to exercise a relaunch was to go for a walk.
//

import CoreLocation
import Foundation
@testable import OpenTrails
import OpenTrailsShared
import SwiftData
import Testing

/// Stands in for the app's second `CLLocationManager` — the significant-change
/// one. Records what the tracker asked it to do, and answers the two
/// authorization questions however the test says.
final class StubLocationMonitor: SignificantLocationMonitor {
    enum Authorization {
        case notDetermined, whenInUse, always, denied
    }

    var authorization: Authorization = .notDetermined
    private(set) var isMonitoring = false
    private(set) var alwaysAccessRequests = 0
    private(set) var startCount = 0
    private(set) var stopCount = 0
    weak var monitorDelegateObject: AnyObject?

    var isAlwaysAuthorized: Bool { authorization == .always }

    var canRequestAlwaysAccess: Bool {
        authorization == .notDetermined || authorization == .whenInUse
    }

    var monitorDelegate: CLLocationManagerDelegate? {
        get { monitorDelegateObject as? CLLocationManagerDelegate }
        set { monitorDelegateObject = newValue }
    }

    func requestAlwaysAccess() { alwaysAccessRequests += 1 }

    func startSignificantLocationUpdates() {
        isMonitoring = true
        startCount += 1
    }

    func stopSignificantLocationUpdates() {
        isMonitoring = false
        stopCount += 1
    }

    /// Delivers a fix exactly as CoreLocation does — through the delegate the
    /// tracker registered, not by calling into it directly.
    func deliver(_ location: CLLocation) {
        monitorDelegate?.locationManager?(CLLocationManager(), didUpdateLocations: [location])
    }

    /// The user answering the Always prompt, long after it was shown.
    func grantAlways() {
        authorization = .always
        monitorDelegate?.locationManagerDidChangeAuthorization?(CLLocationManager())
    }
}

/// A `UserDefaults` nobody else in the process is reading, so a test can seed
/// a "previous launch" without editing the host app's own settings.
func makeScratchDefaults() throws -> UserDefaults {
    let suite = "OpenTrailsTests.\(UUID().uuidString)"
    return try #require(UserDefaults(suiteName: suite))
}

/// Lets the `Task { @MainActor in … }` hop that every delegate callback in
/// this app makes actually run.
func settleDelegateHop() async {
    for _ in 0..<8 { await Task.yield() }
}

// MARK: - Authorization

/// No App Group needed: none of these publish anything. They're about which
/// CoreLocation calls the tracker makes, and when.
@Suite("Background tracking authorization")
final class BackgroundTrackingAuthorizationTests {
    private let container: ModelContainer
    private let defaults: UserDefaults
    private let monitor = StubLocationMonitor()
    /// Held for the length of the test: the monitor references its delegate
    /// weakly, exactly as CoreLocation does.
    private var retainedTracker: BackgroundTrailTracker?

    init() throws {
        container = try Fixture.modelContainer()
        defaults = try makeScratchDefaults()
    }

    @discardableResult private func makeTracker() -> BackgroundTrailTracker {
        let newTracker = BackgroundTrailTracker(container: container, monitor: monitor, defaults: defaults)
        retainedTracker = newTracker
        return newTracker
    }

    @Test("turning tracking on with Always already granted starts monitoring")
    func enablingWhenAuthorizedStarts() {
        monitor.authorization = .always
        let tracker = makeTracker()

        tracker.setEnabled(true)

        #expect(monitor.isMonitoring)
        #expect(monitor.alwaysAccessRequests == 0, "there is nothing left to ask for")
    }

    /// The common path: the app already has When In Use for the map, and
    /// Always is a second prompt the user answers outside the app.
    @Test("turning tracking on without Always asks for it rather than starting")
    func enablingWithoutAlwaysAsks() {
        for authorization in [StubLocationMonitor.Authorization.notDetermined, .whenInUse] {
            let localMonitor = StubLocationMonitor()
            localMonitor.authorization = authorization
            let localTracker = BackgroundTrailTracker(container: container, monitor: localMonitor, defaults: defaults)
            retainedTracker = localTracker

            localTracker.setEnabled(true)

            #expect(localMonitor.alwaysAccessRequests == 1, "\(authorization)")
            #expect(!localMonitor.isMonitoring, "monitoring without Always would never deliver anything")
        }
    }

    /// A refusal is an answer. Re-prompting can't change it — only Settings
    /// can — so the toggle must not keep asking.
    @Test("a refused app asks for nothing and starts nothing")
    func deniedAuthorizationDoesNothing() {
        monitor.authorization = .denied
        let tracker = makeTracker()

        tracker.setEnabled(true)

        #expect(monitor.alwaysAccessRequests == 0)
        #expect(!monitor.isMonitoring)
    }

    @Test("turning tracking off stops monitoring")
    func disablingStops() {
        monitor.authorization = .always
        let tracker = makeTracker()
        tracker.setEnabled(true)

        tracker.setEnabled(false)

        #expect(!monitor.isMonitoring)
        #expect(monitor.stopCount == 1)
    }

    /// The grant arrives minutes later, from a system prompt shown after the
    /// user has left the app. Nothing else will start monitoring for them.
    @Test("granting Always afterwards arms monitoring")
    func grantingAlwaysLaterStarts() async {
        defaults.set(true, forKey: SettingsKey.backgroundTrackingEnabled)
        let tracker = makeTracker()
        tracker.setEnabled(true)
        #expect(!monitor.isMonitoring, "precondition: the prompt is still open")

        monitor.grantAlways()
        await settleDelegateHop()

        #expect(monitor.isMonitoring)
    }

    /// …but only if the feature is actually on. Always may be granted for
    /// reasons of its own, and an authorization callback is not consent to
    /// start spending battery.
    @Test("granting Always with the feature off starts nothing")
    func grantingAlwaysWhileDisabledStartsNothing() async {
        defaults.set(false, forKey: SettingsKey.backgroundTrackingEnabled)
        makeTracker()

        monitor.grantAlways()
        await settleDelegateHop()

        #expect(!monitor.isMonitoring)
    }

    /// Monitoring doesn't survive a process launch: the system wakes the app
    /// *so that* it can re-register and receive the pending event. An app that
    /// doesn't re-arm here simply stops updating, silently, forever.
    @Test("a launch with tracking on and Always granted re-arms monitoring")
    func launchReArmsMonitoring() {
        defaults.set(true, forKey: SettingsKey.backgroundTrackingEnabled)
        monitor.authorization = .always

        makeTracker()

        #expect(monitor.isMonitoring, "the wake-up is wasted otherwise")
    }

    @Test("a launch with tracking off re-arms nothing")
    func launchWithoutTrackingDoesNotArm() {
        monitor.authorization = .always
        makeTracker()
        #expect(!monitor.isMonitoring)
    }
}

// MARK: - Delivery

extension WidgetFeedSuites {
/// These write the App Group payload, so they share the file the other two
/// feed suites use and are serialized alongside them.
@Suite("Background delivery", .serialized)
final class BackgroundDeliveryTests {
    private let container: ModelContainer
    private let context: ModelContext
    private let defaults: UserDefaults
    private let monitor = StubLocationMonitor()
    /// Held for the length of the test: the monitor references its delegate
    /// weakly, exactly as CoreLocation does.
    private var retainedTracker: BackgroundTrailTracker?

    init() throws {
        container = try Fixture.modelContainer()
        context = ModelContext(container)
        defaults = try makeScratchDefaults()
        SharedStore.clear()
    }

    deinit {
        SharedStore.clear()
    }

    /// A hike stored in the container and recorded as the last selection —
    /// which is all a relaunched process has to go on.
    private func selectedHike(route: [RouteCoordinate] = Fixture.ridgeRoute) -> Hike {
        let hike = Fixture.hike(in: context, route: route)
        try? context.save()
        defaults.set(hike.id.uuidString, forKey: SettingsKey.lastSelectedHikeID)
        return hike
    }

    /// A tracker built the way a background relaunch builds one: no selection
    /// call, no published snapshot, nothing but what's on disk.
    @discardableResult private func relaunchedTracker() -> BackgroundTrailTracker {
        let newTracker = BackgroundTrailTracker(container: container, monitor: monitor, defaults: defaults)
        retainedTracker = newTracker
        return newTracker
    }

    private func fix(
        at coordinate: CLLocationCoordinate2D,
        accuracy: CLLocationAccuracy = 10,
        age: TimeInterval = 0
    ) -> CLLocation {
        CLLocation(
            coordinate: coordinate,
            altitude: 0,
            horizontalAccuracy: accuracy,
            verticalAccuracy: -1,
            course: -1,
            speed: -1,
            timestamp: Date().addingTimeInterval(-age)
        )
    }

    /// The whole feature in one test: woken with no in-memory state, the app
    /// matches the fix against the hike `UserDefaults` says was selected and
    /// publishes progress along it.
    @Test("a fix delivered after a relaunch is matched against the persisted selection")
    func backgroundFixPublishesProgress() async throws {
        let hike = selectedHike()
        let profile = RouteProfile(route: hike.route)
        relaunchedTracker()

        monitor.deliver(fix(at: profile.coordinates[3]))
        await settleDelegateHop()

        let snapshot = try #require(SharedStore.load())
        #expect(snapshot.hikeID == hike.id, "the selection came from defaults, not from memory")
        let live = try #require(snapshot.liveFix)
        #expect(abs(live.distanceAlongRouteMeters - profile.distances[3]) < 1)
    }

    /// Off the trail, the widget shows the trail's length rather than a
    /// position that isn't on it.
    @Test("a fix off the trail clears the published position")
    func offRouteFixClearsTheLiveFix() async throws {
        let hike = selectedHike()
        let profile = RouteProfile(route: hike.route)
        relaunchedTracker()

        monitor.deliver(fix(at: profile.coordinates[2]))
        await settleDelegateHop()
        #expect(try #require(SharedStore.load()).liveFix != nil, "precondition: on the trail first")

        // ~900 m west of the ridge, well past the follow threshold.
        monitor.deliver(fix(at: CLLocationCoordinate2D(latitude: 37.3340, longitude: -122.0400)))
        await settleDelegateHop()

        let snapshot = try #require(SharedStore.load())
        #expect(snapshot.liveFix == nil, "a walker who left the trail has no progress along it")
        #expect(snapshot.hikeID == hike.id, "but the trail itself is still what's shown")
    }

    /// Significant-change delivery hands over cached fixes on relaunch, and a
    /// fix from half an hour ago is a position the walker has left.
    @Test("a stale fix is refused")
    func staleFixIsRefused() async {
        let hike = selectedHike()
        let profile = RouteProfile(route: hike.route)
        relaunchedTracker()

        monitor.deliver(fix(at: profile.coordinates[3], age: LocationFixPolicy.backgroundMaximumAge + 60))
        await settleDelegateHop()

        #expect(SharedStore.load() == nil, "nothing should have been published at all")
    }

    /// A fix whose uncertainty is wider than the matching tolerance can't say
    /// which part of a trail someone is on — including whether they're on it.
    @Test("a fix too imprecise to match is refused")
    func impreciseFixIsRefused() async {
        let hike = selectedHike()
        let profile = RouteProfile(route: hike.route)
        relaunchedTracker()

        monitor.deliver(
            fix(at: profile.coordinates[3], accuracy: RouteProfile.followMatchThresholdMeters + 100)
        )
        await settleDelegateHop()

        #expect(SharedStore.load() == nil)
    }

    /// The hike was deleted while the app was suspended, and the wake-up
    /// arrives for a selection that no longer exists.
    @Test("a fix for a hike that has been deleted publishes nothing")
    func deletedHikePublishesNothing() async throws {
        let hike = selectedHike()
        let profile = RouteProfile(route: hike.route)
        relaunchedTracker()
        context.delete(hike)
        try context.save()

        monitor.deliver(fix(at: profile.coordinates[3]))
        await settleDelegateHop()

        #expect(SharedStore.load() == nil, "there is no trail to report progress along")
    }

    /// With nothing recorded as selected there is nothing to match against,
    /// which is what a wake-up before the user has ever picked a trail looks
    /// like.
    @Test("a fix with no persisted selection publishes nothing")
    func noSelectionPublishesNothing() async {
        _ = Fixture.hike(in: context)
        relaunchedTracker()

        monitor.deliver(fix(at: Fixture.ridgeRoute[3].clCoordinate))
        await settleDelegateHop()

        #expect(SharedStore.load() == nil)
    }

    /// The continuity reference `RouteProfile.nearestPoint` needs is persisted
    /// precisely because a relaunch has no memory: on a loop, the fix alone is
    /// ambiguous, and "where were they last time?" is what resolves it.
    @Test("matching continues from the distance the previous launch persisted")
    func matchingResumesFromPersistedDistance() async throws {
        // An out-and-back: at the trailhead the outbound and return legs are
        // less than a metre apart, so the fix alone cannot say which of them
        // the walker is on. Only the persisted distance can.
        let hike = selectedHike(route: Fixture.outAndBackRoute)
        let profile = RouteProfile(route: hike.route)
        let total = try #require(profile.distances.last)
        relaunchedTracker()

        let trailhead = profile.coordinates[0]
        monitor.deliver(fix(at: trailhead))
        await settleDelegateHop()
        let cold = try #require(SharedStore.load()?.liveFix)
        #expect(cold.distanceAlongRouteMeters < total / 2, "with nothing to go on, a fix here is the start")

        // Now the app is relaunched knowing the walker was nearly home.
        defaults.set(total, forKey: BackgroundTrailTracker.Keys.lastMatchedDistance)
        monitor.deliver(fix(at: trailhead))
        await settleDelegateHop()

        let resumed = try #require(SharedStore.load()?.liveFix)
        #expect(
            resumed.distanceAlongRouteMeters > total / 2,
            "a walker finishing an out-and-back must not be reported as just starting it"
        )
    }

    /// And it writes one back, so the *next* wake-up has the same continuity.
    @Test("a matched background fix persists its distance for the next launch")
    func matchedFixPersistsItsDistance() async throws {
        let hike = selectedHike()
        let profile = RouteProfile(route: hike.route)
        relaunchedTracker()

        monitor.deliver(fix(at: profile.coordinates[3]))
        await settleDelegateHop()

        let persisted = defaults.object(forKey: BackgroundTrailTracker.Keys.lastMatchedDistance) as? Double
        #expect(abs(try #require(persisted) - profile.distances[3]) < 1)
    }
}
}
