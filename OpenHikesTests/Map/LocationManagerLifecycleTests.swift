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
}
