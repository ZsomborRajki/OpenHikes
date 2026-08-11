//
//  LocationManager.swift
//  OpenTrails
//
//  Streams the user's location via a classic CLLocationManager delegate.
//
//  Deliberately not the newer `CLLocationUpdate.liveUpdates()` async stream:
//  that API stalls after the first fix when the Simulator's location is driven
//  by `simctl location ... start` (GPX playback), while a delegate-based
//  CLLocationManager keeps receiving updates — the same mechanism MapKit's own
//  `showsUserLocation` dot uses internally, which is why the map kept moving
//  while this stayed frozen.
//

import Foundation
import CoreLocation
import Observation

@MainActor
@Observable
final class LocationManager: NSObject {
    private(set) var coordinate: CLLocationCoordinate2D?

    private let manager = CLLocationManager()
    /// CLLocationManager can deliver updates far more often than once a second;
    /// `coordinate` is `@Observable`, so every write can re-render anything
    /// reading it (this app's map centering, the elevation graph's auto-follow).
    /// Throttled here so downstream consumers only ever see ~1 update/sec.
    private var lastPublished: Date?
    private static let minimumPublishInterval: TimeInterval = 1

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    /// Requests "when in use" authorization on first use (if needed) and starts
    /// updating. Location delivery itself is ongoing via the delegate for as
    /// long as this object lives.
    func start() async {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            manager.startUpdatingLocation()
        case .denied, .restricted:
            break
        @unknown default:
            break
        }
    }

    fileprivate func publish(_ location: CLLocation) {
        let next = location.coordinate
        // `CLLocationCoordinate2D` isn't `Equatable`, so Observation can't tell
        // a repeat fix from a new one and treats the same place as news. A
        // walker standing still at a viewpoint would otherwise wake every
        // observer once a second for as long as the app is open. Nothing
        // downstream wants that heartbeat: auto-follow and the weather poll
        // read `coordinate` on their own timers, and the map only uses it to
        // centre on the very first fix.
        if let coordinate, coordinate.latitude == next.latitude, coordinate.longitude == next.longitude {
            return
        }
        // Only an actual publish restarts the throttle window, so the first
        // step after standing still reaches the map straight away.
        let now = Date()
        if let lastPublished, now.timeIntervalSince(lastPublished) < Self.minimumPublishInterval {
            return
        }
        lastPublished = now
        coordinate = next
    }
}

extension LocationManager: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in publish(location) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            guard status == .authorizedWhenInUse || status == .authorizedAlways else { return }
            manager.startUpdatingLocation()
        }
    }
}
