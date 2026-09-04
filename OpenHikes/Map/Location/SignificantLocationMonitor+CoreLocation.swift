//
//  SignificantLocationMonitor+CoreLocation.swift
//  OpenHikes
//
//  `CLLocationManager` as the tracker's monitor. The `#if os(iOS)` guards
//  live here so the tracker itself has one code path — the one the tests
//  drive through a stub.
//

import CoreLocation

extension CLLocationManager: SignificantLocationMonitor {
    var isAlwaysAuthorized: Bool {
        #if os(iOS)
        authorizationStatus == .authorizedAlways
        #else
        false
        #endif
    }

    var canRequestAlwaysAccess: Bool {
        #if os(iOS)
        switch authorizationStatus {
        case .notDetermined, .authorizedWhenInUse: true
        default: false
        }
        #else
        false
        #endif
    }

    var monitorDelegate: CLLocationManagerDelegate? {
        get { delegate }
        set { delegate = newValue }
    }

    func requestAlwaysAccess() {
        #if os(iOS)
        requestAlwaysAuthorization()
        #endif
    }

    func startSignificantLocationUpdates() {
        #if os(iOS)
        startMonitoringSignificantLocationChanges()
        #endif
    }

    func stopSignificantLocationUpdates() {
        #if os(iOS)
        stopMonitoringSignificantLocationChanges()
        #endif
    }
}
