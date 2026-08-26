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

/// A fix accepted for route matching: where the walker is, and — when they're
/// moving fast enough for it to mean anything — which way they're going.
nonisolated struct RouteFix {
    let coordinate: CLLocationCoordinate2D
    /// Course over ground in degrees from true north, or `nil` when this fix
    /// carries none worth trusting. Route matching uses it to tell the
    /// outbound leg of a trail from the return one.
    let course: CLLocationDirection?
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
    /// Reads the current time for the throttle above. Injectable so a test can
    /// step across the one-second window instead of sleeping through it —
    /// which is both slower and, being a race against a real clock, flakier.
    @ObservationIgnored private let clock: @Sendable () -> Date

    init(
        manager: (any ForegroundLocationSource)? = nil,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.manager = manager ?? CLLocationManager()
        self.clock = clock
        super.init()
        self.manager.foregroundDelegate = self
        self.manager.desiredAccuracy = Self.baselineDesiredAccuracy
        self.manager.distanceFilter = Self.baselineDistanceFilter
    }

    /// Requests "when in use" authorization on first use (if needed) and starts
    /// updating. Location delivery itself is ongoing via the delegate for as
    /// long as this object lives.
    func start() {
        updatesRequested = true
        let status = manager.foregroundAuthorizationStatus
        if status == .notDetermined {
            manager.requestWhenInUseAuthorization()
        } else if Self.isAuthorized(status) {
            manager.startUpdatingLocation()
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
        // a repeat fix from a new one and treats the same place as news. A
        // walker standing still at a viewpoint would otherwise wake every
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
        RenderSignpost.mark("LocationPublished")
        coordinate = next
    }

    /// Returns a current fix only when its uncertainty is narrow enough for
    /// the caller's matching tolerance. Map centering and weather can still
    /// use reduced-accuracy locations through ``coordinate``.
    ///
    /// Position and course come from one `CLLocation` rather than from two
    /// accessors, so a caller can't match a coordinate against the direction
    /// the walker was going at some other moment.
    func routeFix(maximumHorizontalAccuracy: CLLocationAccuracy) -> RouteFix? {
        guard let latestLocation,
              LocationFixPolicy.accepts(
                latestLocation,
                maximumAge: LocationFixPolicy.foregroundMaximumAge,
                maximumHorizontalAccuracy: maximumHorizontalAccuracy
              ) else { return nil }
        return RouteFix(
            coordinate: latestLocation.coordinate,
            course: LocationFixPolicy.course(of: latestLocation)
        )
    }

    /// ``coordinate`` as an async sequence: the fix current when iteration
    /// starts, then one element per accepted publish.
    ///
    /// What matters here is what it *doesn't* emit. `publish(_:)` above
    /// already throttles to one update a second and already drops a fix that
    /// repeats the last coordinate, so a walker standing at a viewpoint — or a
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
        RenderSignpost.mark("LocationFixDelivered")
        onMainActor { [weak self] in self?.publish(location) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        onMainActor { [weak self] in
            guard let self, updatesRequested,
                  Self.isAuthorized(self.manager.foregroundAuthorizationStatus) else { return }
            self.manager.startUpdatingLocation()
        }
    }
}
