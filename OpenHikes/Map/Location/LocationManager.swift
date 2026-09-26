//
//  LocationManager.swift
//  OpenHikes
//
//  Streams the user's location via a classic CLLocationManager delegate.
//
//  Deliberately not the newer `CLLocationUpdate.liveUpdates()` async stream:
//  that API stalls after the first fix when the Simulator's location is driven
//  by `simctl location ... start` (GPX playback), while a delegate-based
//  CLLocationManager keeps receiving updates — MapKit's own
//  `showsUserLocation` dot kept moving while this stayed frozen.
//

import CoreLocation
import Foundation
import Observation

/// A fix accepted for route matching: where the hiker is, and — when they're
/// moving fast enough for it to mean anything — which way they're going.
nonisolated struct RouteFix {
    let coordinate: CLLocationCoordinate2D
    /// Course over ground in degrees from true north, or `nil` when this fix
    /// carries none worth trusting. Route matching uses it to tell the
    /// outbound leg of a trail from the return one.
    let course: CLLocationDirection?
    /// When the receiver took the fix, which is up to
    /// ``LocationFixPolicy/foregroundMaximumAge`` before it is read here.
    /// Carried so anything ordering this feed's evidence against the
    /// background one's orders it by when the hiker was somewhere rather
    /// than by when the app got round to asking.
    let timestamp: Date
}

nonisolated enum LocationFixPolicy {
    static let foregroundMaximumAge: TimeInterval = 30
    static let backgroundMaximumAge: TimeInterval = 5 * 60
    private static let futureTimestampTolerance: TimeInterval = 5

    /// Below this speed a receiver's course is noise. A phone lying still on
    /// a rock still reports *some* direction, and it wanders; 0.5 m/s is
    /// under even a slow uphill walking pace and well clear of that drift.
    static let minimumCourseSpeed: CLLocationSpeed = 0.5

    /// A course this uncertain says nothing about which way along a trail
    /// someone is walking, so it's treated as no course at all.
    static let maximumCourseAccuracy: CLLocationDirectionAccuracy = 45

    /// The direction of travel a fix carries, or `nil` when it carries none
    /// worth trusting. Shared by the foreground and background feeds so both
    /// answer "which way are they walking?" identically — a disagreement
    /// there would show up as the app and its widget reporting two different
    /// percentages of the same trail.
    static func course(of location: CLLocation) -> CLLocationDirection? {
        guard location.speed >= minimumCourseSpeed, location.course >= 0 else { return nil }
        // A negative accuracy means the receiver reported no uncertainty at
        // all — which is what simulated locations and plenty of recorded
        // tracks carry — not that the course is bad. Only an uncertainty that
        // is both reported and wide disqualifies it; absence of evidence is
        // left to the speed gate above.
        if location.courseAccuracy >= 0, location.courseAccuracy > maximumCourseAccuracy { return nil }
        return location.course
    }

    static func accepts(
        _ location: CLLocation,
        maximumAge: TimeInterval,
        maximumHorizontalAccuracy: CLLocationAccuracy? = nil,
        now: Date = .now
    ) -> Bool {
        guard CLLocationCoordinate2DIsValid(location.coordinate),
              location.horizontalAccuracy >= 0 else { return false }

        let age = now.timeIntervalSince(location.timestamp)
        guard age >= -futureTimestampTolerance, age <= maximumAge else { return false }

        if let maximumHorizontalAccuracy,
           location.horizontalAccuracy > maximumHorizontalAccuracy { return false }
        return true
    }
}

/// The slice of `CLLocationManager` the foreground map feed needs.
///
/// Kept tiny and injected so tests can verify battery-related tuning and the
/// authorization/start lifecycle without walking outside.
protocol ForegroundLocationSource: AnyObject {
    var foregroundAuthorizationStatus: CLAuthorizationStatus { get }
    var foregroundDelegate: CLLocationManagerDelegate? { get set }

    var desiredAccuracy: CLLocationAccuracy { get set }
    var distanceFilter: CLLocationDistance { get set }

    func requestWhenInUseAuthorization()
    func startUpdatingLocation()
    /// Ends delivery. Part of the seam rather than left to the manager's
    /// deallocation, because this manager is never deallocated: it belongs to
    /// the app model, which lives for the process. See ``LocationManager/stop()``.
    func stopUpdatingLocation()
}

extension CLLocationManager: ForegroundLocationSource {
    var foregroundAuthorizationStatus: CLAuthorizationStatus { authorizationStatus }

    var foregroundDelegate: CLLocationManagerDelegate? {
        get { delegate }
        set { delegate = newValue }
    }
}

@Observable
final class LocationManager: NSObject {
    /// Non-isolated so releasing the last reference never requires proving
    /// we're on the main actor — deinit does nothing actor-sensitive, and
    /// without this, dropping a `LocationManager` off the main actor (e.g. a
    /// main-actor-isolated test suite instance deallocated on Swift Testing's
    /// cooperative pool) traps in `MainActor.assumeIsolated`.
    nonisolated deinit { /* intentionally empty */ }

    private(set) var coordinate: CLLocationCoordinate2D?

    /// Whether there has been a fix at all this launch.
    ///
    /// The low-frequency half of ``coordinate``: written once, from `false`
    /// to `true`, so a SwiftUI body can decide whether to *offer* something at
    /// the hiker's position without enrolling in the fix feed. Observation
    /// registers per property, so reading this reads nothing else. The
    /// coordinate itself is read in the action that uses it.
    private(set) var hasFix = false

    /// What CoreLocation currently allows this app, as the app's own
    /// observable state.
    ///
    /// Kept rather than read off the source when needed, because a refusal
    /// nothing holds is a refusal nothing can show: the map's location button
    /// and the background-tracking switch both have to be able to say why
    /// they cannot work.
    ///
    /// Low-frequency in a way ``coordinate`` is not — it changes when the
    /// hiker answers a prompt or visits Settings — so a SwiftUI body may read
    /// it. Observation registers per property, so reading this one does not
    /// enrol the reader in the fix feed beside it.
    private(set) var authorizationStatus: CLAuthorizationStatus

    /// Whether the hiker has refused this app location outright.
    ///
    /// The one state worth putting in front of them, because it is the one
    /// nothing in the app can move: `.notDetermined` is answered by asking,
    /// and both authorized cases work. `.restricted` joins `.denied` because
    /// the two are the same from here — there is no fix coming, and the only
    /// place either can change is Settings.
    var isAccessDenied: Bool {
        authorizationStatus == .denied || authorizationStatus == .restricted
    }

    /// Whether the app may use location while it is closed.
    ///
    /// Read by the background-tracking switch in Settings, which is a feature
    /// this object serves none of — and is here anyway, because the grant is
    /// the *app's* and there is one of it. ``BackgroundTrailTracker`` asks its
    /// own `CLLocationManager` the same question through
    /// ``SignificantLocationMonitor/isAlwaysAuthorized`` and gets the same
    /// answer; what it cannot do is make that answer observable, and a second
    /// copy of a system-wide fact is a second thing to keep in step.
    var hasAlwaysAccess: Bool {
        authorizationStatus == .authorizedAlways
    }

    @ObservationIgnored private var latestLocation: CLLocation?

    @ObservationIgnored private let manager: any ForegroundLocationSource
    private static let baselineDesiredAccuracy = kCLLocationAccuracyNearestTenMeters
    /// What limits this feed's rate: Core Location delivers only once the
    /// hiker has moved this far from the last fix, so standing still produces
    /// nothing and walking a fix every twenty seconds or so.
    private static let baselineDistanceFilter: CLLocationDistance = 25
    /// Set by ``start()``: the map has appeared and wants a feed. Nothing turns
    /// the receiver on before that, because `start()` is also where the
    /// authorization prompt comes from.
    private var updatesRequested = false
    /// Whether the receiver is running, so ``reconcile()`` calls CoreLocation
    /// only when its answer changes.
    private var isUpdating = false
    /// Whether the scene is in front of the hiker. The authorization callback
    /// cannot stand in for this: a grant made in Settings arrives while this
    /// app is in the background.
    @ObservationIgnored private var isForeground = true

    init(manager: (any ForegroundLocationSource)? = nil) {
        let source = manager ?? CLLocationManager()
        self.manager = source
        // Read before the delegate is assigned, so the property is truthful
        // from the first body that reads it rather than from the first
        // callback. CoreLocation does deliver one on assignment, but a view
        // built in the same turn would otherwise see `.notDetermined` for an
        // install that settled this months ago.
        authorizationStatus = source.foregroundAuthorizationStatus
        super.init()
        self.manager.foregroundDelegate = self
        self.manager.desiredAccuracy = Self.baselineDesiredAccuracy
        self.manager.distanceFilter = Self.baselineDistanceFilter
    }

    /// Requests "when in use" authorization on first use (if needed) and starts
    /// updating.
    func start() {
        updatesRequested = true
        isForeground = true
        reconcile()
        if authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
    }

    /// Stops the receiver without forgetting that the screen wants it.
    ///
    /// Called when the scene resigns the foreground, and nothing else would
    /// end the request: a `CLLocationManager` stops when it is deallocated,
    /// and this one belongs to the app model, which lives for the process.
    /// Nothing is lost by stopping. Everything this feed drives is on screen,
    /// from the map's first-fix centring to the hike detail's auto-follow, and
    /// the feeds meant to outlive the foreground are other objects: the
    /// recorder's own manager, and ``BackgroundTrailTracker``'s
    /// significant-change delivery.
    func stop() {
        isForeground = false
        reconcile()
    }

    /// Starts the receiver again after ``stop()``, if ``start()`` has asked for
    /// it and access is granted.
    ///
    /// Re-reads the grant on the way in, because a trip to Settings is how a
    /// refusal gets reversed, so the map's button is right on the first frame
    /// back rather than whenever the callback lands. Never prompts: the scene
    /// can become active before the map has appeared, and until then nobody
    /// has decided to ask.
    func resume() {
        isForeground = true
        reconcile()
    }

    /// Brings the receiver in line with the one rule this feed follows: it runs
    /// while the map has asked for it, the scene is in front, and access is
    /// granted.
    ///
    /// Every entry point — ``start()``, ``stop()``, ``resume()`` and the
    /// authorization callback — changes its own input and calls this, rather
    /// than deciding for itself. Deciding separately is how a grant made in
    /// Settings once started the GPS behind a backgrounded app: that path
    /// checked every condition but the foreground one.
    ///
    /// Records the grant on every call, whatever else happens, so a refusal
    /// reaches the screen that has to say so. A write of the value already
    /// there notifies nobody, because `CLAuthorizationStatus` is `Equatable`
    /// (see *Render isolation, in practice*).
    private func reconcile() {
        let status = manager.foregroundAuthorizationStatus
        authorizationStatus = status
        let shouldUpdate = updatesRequested && isForeground && Self.isAuthorized(status)
        guard shouldUpdate != isUpdating else { return }
        isUpdating = shouldUpdate
        if shouldUpdate {
            manager.startUpdatingLocation()
        } else {
            manager.stopUpdatingLocation()
        }
    }

    private static func isAuthorized(_ status: CLAuthorizationStatus) -> Bool {
        #if os(macOS)
        status == .authorizedAlways
        #elseif os(visionOS)
        status == .authorizedWhenInUse
        #else
        status == .authorizedWhenInUse || status == .authorizedAlways
        #endif
    }

    private func publish(_ location: CLLocation) {
        guard LocationFixPolicy.accepts(
            location,
            maximumAge: LocationFixPolicy.foregroundMaximumAge
        ) else { return }
        latestLocation = location

        let next = location.coordinate
        // `CLLocationCoordinate2D` isn't `Equatable`, so Observation can't tell
        // a repeat fix from a new one and would wake every observer for the
        // same place. The distance filter keeps a hiker standing still from
        // producing fixes at all, but Core Location sends a fresh first fix
        // each time `resume()` restarts it, and that one can repeat the last.
        if let coordinate, coordinate.latitude == next.latitude, coordinate.longitude == next.longitude { return }
        coordinate = next
        hasFix = true
    }

    /// Returns a current fix only when its uncertainty is narrow enough for
    /// the caller's matching tolerance. Map centering and weather can still
    /// use reduced-accuracy locations through ``coordinate``.
    ///
    /// Position and course come from one `CLLocation` rather than from two
    /// accessors, so a caller can't match a coordinate against the direction
    /// the hiker was going at some other moment.
    func routeFix(maximumHorizontalAccuracy: CLLocationAccuracy) -> RouteFix? {
        guard let latestLocation,
              LocationFixPolicy.accepts(
                latestLocation,
                maximumAge: LocationFixPolicy.foregroundMaximumAge,
                maximumHorizontalAccuracy: maximumHorizontalAccuracy
              ) else { return nil }
        return RouteFix(
            coordinate: latestLocation.coordinate,
            course: LocationFixPolicy.course(of: latestLocation),
            timestamp: latestLocation.timestamp
        )
    }

    /// ``coordinate`` as an async sequence: the fix current when iteration
    /// starts, then the latest one each time a new fix is published. Fixes
    /// published before a consumer gets to run reach it as one element, the
    /// newest.
    ///
    /// What matters here is what it *doesn't* emit. The distance filter keeps
    /// a hiker standing still — or a phone in a pocket — from producing
    /// fixes, and ``publish(_:)`` drops one that repeats the last coordinate,
    /// so the hike detail's auto-follow wakes only when the hiker has moved
    /// rather than on a timer through every rest stop.
    ///
    /// Consumers stay on the main actor: the sequence inherits the isolation
    /// of whoever asks for it, and this is main-actor state.
    var fixes: Observations<CLLocationCoordinate2D?, Never> {
        Observations { self.coordinate }
    }
}

extension LocationManager: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        onMainActor { [weak self] in self?.publish(location) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        // Recorded whatever the scene is doing, and acted on only in front —
        // both are `reconcile()`'s to decide.
        onMainActor { [weak self] in self?.reconcile() }
    }
}
