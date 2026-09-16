//
//  BackgroundTrackingTests.swift
//  OpenHikesTests
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
@testable import OpenHikes
import OpenHikesShared
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
    ///
    /// The tracker's `nonisolated` callbacks reach main-actor state through
    /// `onMainActor`, which runs the body synchronously when the caller is
    /// already on the main actor — and a main-actor-isolated test always is.
    /// So the tracker has *started* handling the fix by the time this returns,
    /// and anything it decides synchronously (whether the fix is accepted at
    /// all, which hike it belongs to) is already settled. Matching it against
    /// the route and writing the App Group snapshot are not: both were moved
    /// off the main actor, so a test asserting on the store waits through
    /// ``BackgroundDeliveryTests/deliver(_:)``.
    func deliver(_ location: CLLocation) {
        monitorDelegate?.locationManager?(CLLocationManager(), didUpdateLocations: [location])
    }

    /// The user answering the Always prompt, long after it was shown.
    /// Synchronous: nothing about arming monitoring leaves the main actor.
    func grantAlways() {
        authorization = .always
        monitorDelegate?.locationManagerDidChangeAuthorization?(CLLocationManager())
    }
}

/// A `UserDefaults` nobody else in the process is reading, so a test can seed
/// a "previous launch" without editing the host app's own settings.
func makeScratchDefaults() throws -> UserDefaults {
    let suite = "OpenHikesTests.\(UUID().uuidString)"
    return try #require(UserDefaults(suiteName: suite))
}

/// No App Group needed: none of these publish anything. They're about which
/// CoreLocation calls the tracker makes, and when.
@Suite("Background tracking authorization")
final class BackgroundTrackingAuthorizationTests {
    private let container: ModelContainer
    private let defaults: UserDefaults
    private let monitor = StubLocationMonitor()
    // periphery:ignore - assigned and never read on purpose; it is the strong
    // reference that keeps the tracker alive.
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

    /// Records a selection the way a previous launch would have left one.
    ///
    /// Monitoring is armed only when there is a trail to match fixes against,
    /// and these tests are about the other two conditions — so the id is all
    /// they need, and it never has to name a hike that exists.
    private func seedSelection() {
        defaults.set(UUID().uuidString, forKey: SettingsKey.lastSelectedHikeID)
    }

    @Test("turning tracking on with Always already granted starts monitoring")
    func enablingWhenAuthorizedStarts() {
        monitor.authorization = .always
        seedSelection()
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

            // Nothing is selected here, and the prompt still goes up: the
            // toggle is a standing preference, and answering it is a trip out
            // of the app the user shouldn't repeat when they pick a trail.
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
        seedSelection()
        let tracker = makeTracker()
        tracker.setEnabled(true)
        // Not zero: the launch above found the toggle off and stood monitoring
        // down, which is how a registration left over from a previous launch
        // is cancelled. This test is about the *next* stop.
        let stopsBeforeDisabling = monitor.stopCount

        tracker.setEnabled(false)

        #expect(!monitor.isMonitoring)
        #expect(monitor.stopCount == stopsBeforeDisabling + 1)
    }

    /// The grant arrives minutes later, from a system prompt shown after the
    /// user has left the app. Nothing else will start monitoring for them.
    @Test("granting Always afterwards arms monitoring")
    func grantingAlwaysLaterStarts() {
        defaults.set(true, forKey: SettingsKey.backgroundTrackingEnabled)
        seedSelection()
        let tracker = makeTracker()
        tracker.setEnabled(true)
        #expect(!monitor.isMonitoring, "precondition: the prompt is still open")

        monitor.grantAlways()

        #expect(monitor.isMonitoring)
    }

    /// …but only if the feature is actually on. Always may be granted for
    /// reasons of its own, and an authorization callback is not consent to
    /// start spending battery.
    @Test("granting Always with the feature off starts nothing")
    func grantingAlwaysWhileDisabledStartsNothing() {
        defaults.set(false, forKey: SettingsKey.backgroundTrackingEnabled)
        makeTracker()

        monitor.grantAlways()

        #expect(!monitor.isMonitoring)
    }

    /// Monitoring doesn't survive a process launch: the system wakes the app
    /// *so that* it can re-register and receive the pending event. An app that
    /// doesn't re-arm here simply stops updating, silently, forever.
    @Test("a launch with tracking on and Always granted re-arms monitoring")
    func launchReArmsMonitoring() {
        defaults.set(true, forKey: SettingsKey.backgroundTrackingEnabled)
        monitor.authorization = .always
        seedSelection()

        makeTracker()

        #expect(monitor.isMonitoring, "the wake-up is wasted otherwise")
    }

    @Test("a launch with tracking off re-arms nothing")
    func launchWithoutTrackingDoesNotArm() {
        monitor.authorization = .always
        seedSelection()
        makeTracker()
        #expect(!monitor.isMonitoring)
    }

    /// The toggle and the grant are not enough on their own. Armed with
    /// nothing selected, every significant change relaunches the app only to
    /// find no hike to match against — which over a long drive is hundreds of
    /// wasted wakes, and the iOS background-location reminder that follows
    /// them.
    @Test("a launch with tracking on but nothing selected arms nothing")
    func launchWithoutSelectionDoesNotArm() {
        defaults.set(true, forKey: SettingsKey.backgroundTrackingEnabled)
        monitor.authorization = .always

        makeTracker()

        #expect(monitor.startCount == 0, "there is no trail to match a fix against")
    }

    /// …and the grant arriving later doesn't change that.
    @Test("granting Always with nothing selected starts nothing")
    func grantingAlwaysWithoutSelectionStartsNothing() {
        defaults.set(true, forKey: SettingsKey.backgroundTrackingEnabled)
        makeTracker()

        monitor.grantAlways()

        #expect(monitor.startCount == 0)
    }
}
