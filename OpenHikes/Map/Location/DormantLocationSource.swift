//
//  DormantLocationSource.swift
//  OpenHikes
//
//  The location stack a launch gets when it must not have one.
//

import CoreLocation
import Foundation

/// A `CLLocationManager` stand-in that reports no access and starts nothing.
///
/// Composed in place of the real manager whenever
/// ``AppLaunchEnvironment/usesLiveLocation`` is false — which is every
/// app-hosted unit-test launch, and every UI-test launch that did not ask for
/// the live feed.
///
/// It exists because "nobody calls `start()`" is a weaker guarantee than "there
/// is no manager to start". ``BackgroundTrailTracker`` arms significant-change
/// monitoring from its own `init` — nobody calls anything — reading a
/// `UserDefaults` flag that in a hosted run belongs to whoever last used the
/// Simulator, and it arms again from an authorization callback that a real
/// `CLLocationManager` can deliver at any point after the delegate is
/// assigned. Both paths end in background relaunch on a machine that was only
/// asked to run a test suite.
///
/// Answering `.denied` rather than `.notDetermined` is what makes it inert
/// rather than merely idle: `.notDetermined` is the one status
/// ``LocationManager/start()`` responds to by putting a system alert on screen.
/// It is also the honest answer — this process has no location access, because
/// it has no location manager.
///
/// Both delegates are `weak`, as `CLLocationManager`'s own is: their owners
/// hold this object, and a strong reference back would leak every one of them.
final class DormantLocationSource: ForegroundLocationSource, SignificantLocationMonitor {
    var foregroundAuthorizationStatus: CLAuthorizationStatus { .denied }
    var isAlwaysAuthorized: Bool { false }
    var canRequestAlwaysAccess: Bool { false }

    weak var foregroundDelegate: CLLocationManagerDelegate?
    weak var monitorDelegate: CLLocationManagerDelegate?

    /// Stored so a caller reading back what it configured sees its own value,
    /// the way it would from a real manager. Nothing consumes them.
    var desiredAccuracy: CLLocationAccuracy = kCLLocationAccuracyBest
    var distanceFilter: CLLocationDistance = kCLDistanceFilterNone

    // Doing nothing is the whole contract: every one of these is a request
    // for hardware, an authorization prompt, or background relaunch.
    func requestWhenInUseAuthorization() { /* intentionally dormant */ }
    func startUpdatingLocation() { /* intentionally dormant */ }
    func requestAlwaysAccess() { /* intentionally dormant */ }
    func startSignificantLocationUpdates() { /* intentionally dormant */ }
    func stopSignificantLocationUpdates() { /* nothing was ever started */ }
}
