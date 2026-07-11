//
//  LocationManager.swift
//  OpenTrails
//
//  Streams the user's location via async CLLocationUpdate updates.
//

import Foundation
import CoreLocation
import Observation

@MainActor
@Observable
final class LocationManager {
    private(set) var coordinate: CLLocationCoordinate2D?

    /// Starts streaming location updates, prompting for "when in use" authorization
    /// on first use. Runs until the surrounding task is cancelled.
    func start() async {
        do {
            for try await update in CLLocationUpdate.liveUpdates() {
                if let location = update.location {
                    coordinate = location.coordinate
                }
            }
        } catch {
            // Stream ended or failed (e.g. authorization denied); nothing to recover.
        }
    }
}
