//
//  SignificantLocationFeed.swift
//  OpenHikes
//
//  Significant-location-change delivery, for consumers that want to know the
//  hiker has *moved* rather than where they are this second.
//
//  A third location feed, and the reason there are three is that they answer
//  three different questions. ``LocationManager`` answers "where are they
//  now", continuously, for the map and the recorder, and costs the GPS to do
//  it. ``BackgroundTrailTracker`` answers "have they reached a point on the
//  followed trail" while the app is suspended, which is why it is the one that
//  asks for Always authorization. This answers "have they moved far enough
//  that anything keyed to their region is now wrong" — which is the weather
//  badge's question, and it is worth neither the GPS nor a background wake.
//
//  So this is armed only in the foreground. ``OpenHikesModel`` starts it in
//  `sceneDidBecomeActive()` and stops it in `sceneWillResignActive()`, and
//  that is not a detail: significant-change monitoring left armed is a
//  background wake source, and iOS's periodic "has been using your location in
//  the background" reminder is keyed on background location use whether or not
//  the app declares a background mode. ``BackgroundTrailTracker``'s own header
//  spells out why it arms itself only while it has something to do; the same
//  argument applies here, and in the foreground the answer is simply that
//  nothing this feed drives is on screen when the app is not.
//
//  Foreground-only also means When In Use is enough. Nothing here requests
//  authorization: `LocationManager.start()` already asks, and starting
//  significant-change delivery on a manager with no access is inert rather
//  than an error — it simply never delivers.
//

import CoreLocation
import Foundation
import Observation

/// The hiker's position, as of the last time they moved appreciably.
///
/// `coordinate` is `nil` until the first delivery. Significant-change
/// monitoring reports once as soon as it is started — the same behaviour
/// ``MovementReminderController`` relies on — so in practice that wait is
/// short wherever the app has a recent fix to hand.
@Observable
final class SignificantLocationFeed: NSObject {
    /// Non-isolated so releasing the last reference never requires proving
    /// we're on the main actor — see ``LocationManager``'s deinit for why.
    nonisolated deinit { /* intentionally empty */ }

    private(set) var coordinate: CLLocationCoordinate2D?

    @ObservationIgnored private let monitor: any SignificantLocationMonitor
    @ObservationIgnored private var isMonitoring = false

    /// `nil` composes the real `CLLocationManager`, matching
    /// ``LocationManager/init(manager:clock:)``: a launch that must not have a
    /// location stack passes ``DormantLocationSource`` instead, and one that
    /// may passes nothing.
    init(monitor: (any SignificantLocationMonitor)? = nil) {
        self.monitor = monitor ?? CLLocationManager()
        super.init()
        self.monitor.monitorDelegate = self
    }

    /// Arms delivery. Idempotent, because the scene can report becoming active
    /// more than once for one trip to the foreground.
    func start() {
        guard !isMonitoring else { return }
        isMonitoring = true
        monitor.startSignificantLocationUpdates()
    }

    func stop() {
        guard isMonitoring else { return }
        isMonitoring = false
        monitor.stopSignificantLocationUpdates()
    }

    /// The feed as an async sequence, for a poll loop to wake on. Same shape
    /// as ``LocationManager/fixes``.
    var movements: Observations<CLLocationCoordinate2D?, Never> {
        Observations { self.coordinate }
    }

    /// Publishes a delivery, or drops it.
    ///
    /// `backgroundMaximumAge` rather than the foreground one: significant
    /// changes are handed over on the system's schedule, not on request, and a
    /// fix a couple of minutes old is the normal case here rather than a stale
    /// one. Repeats are dropped for the reason ``LocationManager/publish(_:)``
    /// drops them — `CLLocationCoordinate2D` is not `Equatable`, so
    /// Observation would treat the same place as news and wake every consumer.
    private func publish(_ location: CLLocation) {
        guard LocationFixPolicy.accepts(
            location,
            maximumAge: LocationFixPolicy.backgroundMaximumAge
        ) else { return }
        let next = location.coordinate
        if let coordinate,
           coordinate.latitude == next.latitude,
           coordinate.longitude == next.longitude { return }
        coordinate = next
    }
}

extension SignificantLocationFeed: CLLocationManagerDelegate {
    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        guard let location = locations.last else { return }
        onMainActor { [weak self] in self?.publish(location) }
    }
}
