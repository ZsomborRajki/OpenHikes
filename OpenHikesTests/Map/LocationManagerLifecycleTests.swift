//
//  LocationManagerLifecycleTests.swift
//  OpenHikesTests
//
//  When the foreground feed is running, which is a different question from how
//  it is configured — `LocationManagerConfigurationTests` owns that one.
//
//  Worth its own suite because the answer used to be "from the first time the
//  map appeared until the process died". A `CLLocationManager` stops when it is
//  deallocated and this one is never deallocated, so nothing ended the app's
//  standing request for location: measured on 2026-09-17, MapKit's own manager
//  issued `stopUpdatingLocation` on the way to the background and this app's
//  issued none.
//

import CoreLocation
@testable import OpenHikes
import Testing

@Suite("Foreground location manager lifecycle")
struct LocationManagerLifecycleTests {
    /// Counts the lifecycle calls rather than the configuration ones.
    private final class StubLifecycleLocationSource: ForegroundLocationSource {
        var foregroundAuthorizationStatus: CLAuthorizationStatus = .authorizedWhenInUse
        weak var delegateObject: AnyObject?

        var desiredAccuracy: CLLocationAccuracy = kCLLocationAccuracyThreeKilometers
        var distanceFilter: CLLocationDistance = kCLDistanceFilterNone

        private(set) var requestWhenInUseAuthorizationCalls = 0
        private(set) var startCalls = 0
        private(set) var stopCalls = 0

        var foregroundDelegate: CLLocationManagerDelegate? {
            get { delegateObject as? CLLocationManagerDelegate }
            set { delegateObject = newValue }
        }

        func requestWhenInUseAuthorization() { requestWhenInUseAuthorizationCalls += 1 }
        func startUpdatingLocation() { startCalls += 1 }
        func stopUpdatingLocation() { stopCalls += 1 }
    }

    private let source = StubLifecycleLocationSource()
    private let manager: LocationManager

    init() {
        manager = LocationManager(manager: source)
    }

    @Test("resigning the foreground ends the receiver's request")
    func stopEndsUpdates() {
        manager.start()

        manager.stop()

        #expect(source.stopCalls == 1)
    }

    /// The scene resigns on every interruption — a call, Control Center, the
    /// app switcher — and on a launch whose map has not appeared there is
    /// nothing running to end. Calling into CoreLocation anyway would be a
    /// message about a client that never existed.
    @Test("a stop before anything started reaches nothing")
    func stopBeforeStartIsInert() {
        manager.stop()

        #expect(source.stopCalls == 0)
    }

    @Test("a second stop does not repeat itself")
    func stopIsIdempotent() {
        manager.start()

        manager.stop()
        manager.stop()

        #expect(source.stopCalls == 1)
    }

    @Test("coming back to the foreground restarts what stopping paused")
    func resumeRestartsAfterStop() {
        manager.start()
        manager.stop()

        manager.resume()

        #expect(source.startCalls == 2)
        #expect(source.requestWhenInUseAuthorizationCalls == 0)
    }

    /// The guard that keeps `sceneDidBecomeActive` from bringing the
    /// authorization alert forward: the scene becomes active before
    /// `OpenHikesView.onAppear` runs, and until that has asked for a feed there
    /// is nothing to resume and nobody has decided to prompt.
    @Test("a scene coming forward before the map appeared starts nothing")
    func resumeWithoutStartIsInert() {
        manager.resume()

        #expect(source.startCalls == 0)
        #expect(source.requestWhenInUseAuthorizationCalls == 0)
    }

    @Test("resuming while access is denied starts nothing")
    func resumeStaysInertWhenDenied() {
        manager.start()
        manager.stop()
        source.foregroundAuthorizationStatus = .denied

        manager.resume()

        #expect(source.startCalls == 1)
    }

    /// SwiftUI can run `onAppear` more than once for one screen, and the
    /// authorization callback arrives whenever the hiker has been to Settings.
    @Test("starting twice asks CoreLocation once")
    func startIsIdempotent() {
        manager.start()
        manager.start()

        #expect(source.startCalls == 1)
    }

    /// A resume that follows no stop is still a no-op, so a scene bouncing
    /// through `.inactive` and back cannot stack up requests.
    @Test("resuming a running feed does not restart it")
    func resumeWhileRunningIsInert() {
        manager.start()

        manager.resume()

        #expect(source.startCalls == 1)
    }

    // MARK: The grant answered somewhere else

    /// The bug this half of the suite exists for: granting access happens in
    /// the *Settings* app, so the callback that reports it arrives to an app
    /// that is in the background — and the handler used to start the GPS on
    /// it. That is the standing request `stop()` exists to end, let back in
    /// through the one door the foreground cannot see.
    @Test("a grant answered in Settings does not start the feed from the background")
    func authorizationGrantedWhileBackgroundedStartsNothing() {
        source.foregroundAuthorizationStatus = .notDetermined
        manager.start()
        manager.stop()

        source.foregroundAuthorizationStatus = .authorizedWhenInUse
        manager.locationManagerDidChangeAuthorization(CLLocationManager())

        #expect(source.startCalls == 0)
    }

    /// …and the other half of it: the hiker comes back to an app that now has
    /// the grant, and the feed starts on the way in rather than never.
    @Test("coming back from Settings with the grant starts the feed")
    func resumeAfterGrantStartsTheFeed() {
        source.foregroundAuthorizationStatus = .notDetermined
        manager.start()
        manager.stop()
        source.foregroundAuthorizationStatus = .authorizedWhenInUse
        manager.locationManagerDidChangeAuthorization(CLLocationManager())

        manager.resume()

        #expect(source.startCalls == 1)
    }

    /// The case that must keep working: a hiker who answers the app's own
    /// prompt is looking at the map while they do it, so that grant starts the
    /// feed where it stands.
    @Test("answering the prompt in the foreground starts the feed at once")
    func authorizationGrantedInForegroundStartsTheFeed() {
        source.foregroundAuthorizationStatus = .notDetermined
        manager.start()

        source.foregroundAuthorizationStatus = .authorizedWhenInUse
        manager.locationManagerDidChangeAuthorization(CLLocationManager())

        #expect(source.startCalls == 1)
    }

    // MARK: What the refusal leaves behind

    /// The status is the app's own state now, because a refusal used to be
    /// invisible: every branch read it off CoreLocation, returned quietly, and
    /// kept nothing a screen could show.
    @Test("the status is readable before any callback arrives")
    func statusIsSeededAtInit() {
        let denied = StubLifecycleLocationSource()
        denied.foregroundAuthorizationStatus = .denied

        let refused = LocationManager(manager: denied)

        #expect(refused.authorizationStatus == .denied)
        #expect(refused.isAccessDenied)
    }

    @Test("a refusal answered in Settings is recorded even from the background")
    func refusalIsRecordedWhileBackgrounded() {
        manager.start()
        manager.stop()

        source.foregroundAuthorizationStatus = .denied
        manager.locationManagerDidChangeAuthorization(CLLocationManager())

        #expect(manager.isAccessDenied)
    }

    /// Coming back in re-reads it, which is what lets the map put MapKit's own
    /// button back without waiting for a callback that has already been and
    /// gone.
    @Test("returning to the foreground re-reads the grant")
    func resumeRereadsTheGrant() {
        source.foregroundAuthorizationStatus = .denied
        manager.start()
        #expect(manager.isAccessDenied)
        manager.stop()

        source.foregroundAuthorizationStatus = .authorizedWhenInUse
        manager.resume()

        #expect(!manager.isAccessDenied)
        #expect(manager.authorizationStatus == .authorizedWhenInUse)
    }

    /// `.restricted` is `.denied` from here: there is no fix coming, and the
    /// only place either can change is Settings.
    @Test("a restricted install reads as refused")
    func restrictedCountsAsDenied() {
        let restricted = StubLifecycleLocationSource()
        restricted.foregroundAuthorizationStatus = .restricted

        #expect(LocationManager(manager: restricted).isAccessDenied)
    }

    @Test("an authorized install is not refused")
    func authorizedIsNotDenied() {
        #expect(!manager.isAccessDenied)
    }

    /// Being asked is not being refused — the prompt has not been answered
    /// yet, and a map that drew the refused button here would be reporting a
    /// no the hiker never said.
    @Test("an unanswered prompt is not a refusal")
    func notDeterminedIsNotDenied() {
        let fresh = StubLifecycleLocationSource()
        fresh.foregroundAuthorizationStatus = .notDetermined

        #expect(!LocationManager(manager: fresh).isAccessDenied)
    }

    // MARK: The grant the background-tracking switch reads

    /// The switch's warning row says the hiker's preference and the system's
    /// grant disagree, and this is the system's half. It lives here rather
    /// than on ``BackgroundTrailTracker`` because the grant belongs to the app
    /// and there is one of it — see ``LocationManager/hasAlwaysAccess``.
    @Test("an Always install may run in the background")
    func alwaysHasBackgroundAccess() {
        let always = StubLifecycleLocationSource()
        always.foregroundAuthorizationStatus = .authorizedAlways

        #expect(LocationManager(manager: always).hasAlwaysAccess)
    }

    /// The case the warning row exists for: enough access for the map, and
    /// not enough for the widget to keep up while the app is closed.
    @Test("a When In Use install may not")
    func whenInUseHasNoBackgroundAccess() {
        #expect(!manager.hasAlwaysAccess)
        #expect(!manager.isAccessDenied, "precondition: this is a grant, not a refusal")
    }

    @Test("a refused install may not either")
    func deniedHasNoBackgroundAccess() {
        let denied = StubLifecycleLocationSource()
        denied.foregroundAuthorizationStatus = .denied

        #expect(!LocationManager(manager: denied).hasAlwaysAccess)
    }

    /// The row has to clear itself when the grant arrives, and the grant
    /// arrives in the Settings app — so the read that notices is the one
    /// `resume()` takes on the way back in.
    @Test("upgrading to Always clears the warning on the way back in")
    func upgradingToAlwaysIsNoticed() {
        manager.start()
        #expect(!manager.hasAlwaysAccess, "precondition: When In Use only")
        manager.stop()

        source.foregroundAuthorizationStatus = .authorizedAlways
        manager.resume()

        #expect(manager.hasAlwaysAccess)
    }
}
