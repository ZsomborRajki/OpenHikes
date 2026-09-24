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
import OpenHikesData

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
    /// the hiker's position without enrolling in the once-a-second fix feed.
    /// Observation registers per property, so reading this reads nothing else.
    /// The coordinate itself is read in the action that uses it.
    private(set) var hasFix = false

    /// What CoreLocation currently allows this app, as the app's own
    /// observable state.
    ///
    /// Observable because a refusal used to be invisible. Every branch below
    /// reads the status straight off the source and returns quietly when it
    /// is `.denied`, so an app whose hiker had said no simply had no location
    /// for the rest of the install and said so nowhere: the "my location"
    /// button spun and gave up, the background-tracking switch turned on and
    /// armed nothing. Nothing could tell them because nothing kept the
    /// answer. Reported by the user 2026-09-20.
    ///
    /// Low-frequency in a way ``coordinate`` is not — it changes when the
    /// hiker answers a prompt or visits Settings, which is a handful of times
    /// in the life of an install — so a SwiftUI body may read it. Observation
    /// registers per property, so reading this one does not enrol the reader
    /// in the once-a-second fix feed beside it.
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
    /// CLLocationManager can deliver updates far more often than once a second;
    /// `coordinate` is `@Observable`, so every write can re-render anything
    /// reading it (this app's map centering, the elevation graph's auto-follow).
    /// Throttled here so downstream consumers only ever see ~1 update/sec.
    private var lastPublished: Date?
    private static let baselineDesiredAccuracy = kCLLocationAccuracyNearestTenMeters
    private static let baselineDistanceFilter: CLLocationDistance = 25
    private static let minimumPublishInterval: TimeInterval = 1
    /// Authorization callbacks can arrive as soon as the delegate is assigned.
    /// Only start hardware updates after the owning view has called `start()`.
    private var updatesRequested = false
    /// Whether the receiver is currently running, as distinct from whether the
    /// screen wants it to. ``stop()`` clears this and leaves
    /// ``updatesRequested`` alone, which is what lets ``resume()`` tell "the
    /// map is back" from "the map has never appeared" — the second of which
    /// must not turn anything on, because `start()` is also where the
    /// authorization prompt comes from.
    private var isUpdating = false
    /// Whether the scene is in front of the hiker.
    ///
    /// Tracked because the authorization callback is not a foreground event.
    /// Granting access happens in *Settings*, which means this app is in the
    /// background when the answer arrives — and the callback below used to
    /// call `beginUpdates()` on it regardless, turning the GPS on behind a
    /// screen nobody was looking at and leaving it on until the next resign.
    /// That is the same standing request ``stop()`` exists to prevent, let
    /// back in through the one door that cannot be seen from the front.
    ///
    /// Nothing is lost by refusing there. The hiker comes back to an app that
    /// now has the grant, ``resume()`` runs on the way in, and its guard
    /// passes for the first time — so the feed starts a moment later, on the
    /// frame where it is first worth anything.
    @ObservationIgnored private var isForeground = true
    /// Reads the current time for the throttle above. Injectable so a test can
    /// step across the one-second window instead of sleeping through it —
    /// which is both slower and, being a race against a real clock, flakier.
    @ObservationIgnored private let clock: @Sendable () -> Date

    init(
        manager: (any ForegroundLocationSource)? = nil,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        let source = manager ?? CLLocationManager()
        self.manager = source
        self.clock = clock
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
        let status = manager.foregroundAuthorizationStatus
        record(status)
        if status == .notDetermined {
            manager.requestWhenInUseAuthorization()
        } else if Self.isAuthorized(status) {
            beginUpdates()
        }
    }

    /// Stops the receiver without forgetting that the screen wants it.
    ///
    /// Called when the scene resigns the foreground, and the reason it has to
    /// be called at all is that nothing else will. A `CLLocationManager` stops
    /// when it is deallocated, and this one is never deallocated: it belongs to
    /// the app model, which lives for the process. So an app that had ever
    /// shown its map kept a standing request for location from launch until
    /// the process died — measured on 2026-09-17, where MapKit's own manager
    /// issued `stopUpdatingLocation` on the way to the background and this
    /// one issued nothing at all.
    ///
    /// Nothing is lost by stopping. Everything downstream of this feed is on
    /// screen — the map's centring, the elevation graph's auto-follow, the
    /// weather poll, the widget's live fix, all of which run from
    /// ``fixes`` — and the two feeds that are *meant* to outlive the
    /// foreground are other objects entirely: the recorder's own manager, and
    /// ``BackgroundTrailTracker``'s significant-change delivery.
    func stop() {
        // Ahead of the guard below, and not inside it: a scene that resigns
        // with nothing running has still resigned, and the authorization
        // callback has to know that whether or not there was a feed to end.
        isForeground = false
        guard isUpdating else { return }
        isUpdating = false
        manager.stopUpdatingLocation()
    }

    /// Starts the receiver again after ``stop()``, and only then.
    ///
    /// The guard is the whole of it: a scene becoming active on a launch whose
    /// map has not appeared yet has asked for nothing, and turning updates on
    /// there would put the authorization alert in front of a hiker one step
    /// earlier than ``start()``'s caller decided to.
    func resume() {
        isForeground = true
        let status = manager.foregroundAuthorizationStatus
        // Re-read on the way in because the grant may have changed while the
        // app was away — a trip to Settings is exactly how a refusal gets
        // reversed, and the callback that reported it arrived to a background
        // app. This is the write that lets the button and its alert notice.
        record(status)
        guard updatesRequested, Self.isAuthorized(status) else { return }
        beginUpdates()
    }

    /// Asks the receiver for delivery, at most once per stop.
    ///
    /// Idempotent because its three callers are: the view's `onAppear`, which
    /// SwiftUI may run more than once for one screen; an authorization change,
    /// which arrives whenever the hiker visits Settings; and the scene coming
    /// forward, which happens after every interruption.
    private func beginUpdates() {
        guard !isUpdating else { return }
        isUpdating = true
        manager.startUpdatingLocation()
    }

    /// Records the grant, and only when it has actually changed.
    ///
    /// The dedupe is the point. Three callers write this — `start()`,
    /// `resume()` and the delegate — and `resume()` runs on *every* return to
    /// the foreground, which for a hiker checking the map at a junction is
    /// several times an hour. `authorizationStatus` is observable, and
    /// Observation does not compare before it notifies, so without this each
    /// one of those would wake the map's capsule observation to re-decide a
    /// question whose answer has not moved since the install was set up.
    private func record(_ status: CLAuthorizationStatus) {
        guard status != authorizationStatus else { return }
        authorizationStatus = status
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
        // a repeat fix from a new one and treats the same place as news. A
        // hiker standing still at a viewpoint would otherwise wake every
        // observer once a second for as long as the app is open. Nothing
        // downstream wants that heartbeat: auto-follow and the weather poll
        // are driven by ``fixes``, which carries only what survives this
        // filter, and the map only uses it to centre on the very first fix.
        if let coordinate, coordinate.latitude == next.latitude, coordinate.longitude == next.longitude { return }
        // Only an actual publish restarts the throttle window, so the first
        // step after standing still reaches the map straight away.
        let now = clock()
        if let lastPublished, now.timeIntervalSince(lastPublished) < Self.minimumPublishInterval { return }
        lastPublished = now
        // Marks only the publishes that survive both filters above, so the
        // rate here is the rate every downstream body is allowed to move at.
        // Anything re-rendering faster than this is following something else.
        coordinate = next
        if !hasFix { hasFix = true }
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
    /// starts, then one element per accepted publish.
    ///
    /// What matters here is what it *doesn't* emit. `publish(_:)` above
    /// already throttles to one update a second and already drops a fix that
    /// repeats the last coordinate, so a hiker standing at a viewpoint — or a
    /// phone in a pocket with the screen off — produces no elements at all.
    /// The weather poll and the hike detail's auto-follow each used to run
    /// their own 1 Hz `Task.sleep` loop to discover that for themselves, and
    /// so kept waking through every rest stop to decide they had nothing to
    /// do. Both now wake only when a fix really arrives.
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
        // The other end of the funnel `LocationPublished` closes. The ratio
        // between the two is how much of the location daemon's delivery rate
        // the throttle is absorbing — and a delivery this app throws away is
        // still a fix the GPS spent energy producing, which is what the
        // distance filter, not the throttle, is there to prevent.
        onMainActor { [weak self] in self?.publish(location) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        onMainActor { [weak self] in
            guard let self else { return }
            let status = self.manager.foregroundAuthorizationStatus
            // Recorded whatever the scene is doing: this is the only place a
            // refusal is ever heard, and the screen that has to say so may be
            // built long after it arrives.
            record(status)
            // Acted on only in front. See ``isForeground`` — a grant answered
            // in Settings reaches a backgrounded app, and starting the GPS
            // there is the standing request ``stop()`` exists to end.
            guard updatesRequested, isForeground, Self.isAuthorized(status) else { return }
            beginUpdates()
        }
    }
}
