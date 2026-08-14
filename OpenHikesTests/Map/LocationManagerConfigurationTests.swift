//
//  LocationManagerConfigurationTests.swift
//  OpenHikesTests
//

import CoreLocation
@testable import OpenHikes
import Testing

@Suite("Foreground location manager configuration")
struct LocationManagerConfigurationTests {
    /// Foreground `CLLocationManager` stand-in: records how the manager is
    /// configured and what lifecycle calls it receives.
    private final class StubForegroundLocationSource: ForegroundLocationSource {
        var foregroundAuthorizationStatus: CLAuthorizationStatus = .notDetermined
        weak var delegateObject: AnyObject?

        var desiredAccuracy: CLLocationAccuracy = kCLLocationAccuracyThreeKilometers
        var distanceFilter: CLLocationDistance = kCLDistanceFilterNone

        private(set) var requestWhenInUseAuthorizationCalls = 0
        private(set) var startUpdatingLocationCalls = 0

        var foregroundDelegate: CLLocationManagerDelegate? {
            get { delegateObject as? CLLocationManagerDelegate }
            set { delegateObject = newValue }
        }

        func requestWhenInUseAuthorization() {
            requestWhenInUseAuthorizationCalls += 1
        }

        func startUpdatingLocation() {
            startUpdatingLocationCalls += 1
        }

        func simulateAuthorizationChange(to status: CLAuthorizationStatus) {
            foregroundAuthorizationStatus = status
            foregroundDelegate?.locationManagerDidChangeAuthorization?(CLLocationManager())
        }
    }

    private let source: StubForegroundLocationSource
    private let manager: LocationManager

    init() {
        source = StubForegroundLocationSource()
        manager = LocationManager(manager: source)
    }

    private func settleAuthorizationHop() async {
        for _ in 0..<8 { await Task.yield() }
    }

    @Test("uses nearest-ten-meters accuracy and a distance filter")
    func usesBatteryConsciousDefaults() {
        #expect(source.desiredAccuracy == kCLLocationAccuracyNearestTenMeters)
        #expect(source.distanceFilter == 25)
    }

    @Test("start requests when-in-use authorization while status is undetermined")
    func startRequestsAuthorization() {
        source.foregroundAuthorizationStatus = .notDetermined

        manager.start()

        #expect(source.requestWhenInUseAuthorizationCalls == 1)
        #expect(source.startUpdatingLocationCalls == 0)
    }

    @Test("start immediately begins updates when already authorized")
    func startBeginsUpdatesWhenAuthorized() {
        source.foregroundAuthorizationStatus = .authorizedWhenInUse

        manager.start()

        #expect(source.requestWhenInUseAuthorizationCalls == 0)
        #expect(source.startUpdatingLocationCalls == 1)
    }

    @Test("authorization changes start updates only after start was requested")
    func authorizationCallbackHonorsStartLifecycle() async {
        source.simulateAuthorizationChange(to: .authorizedWhenInUse)
        await settleAuthorizationHop()
        #expect(source.startUpdatingLocationCalls == 0)

        source.foregroundAuthorizationStatus = .notDetermined
        manager.start()
        #expect(source.requestWhenInUseAuthorizationCalls == 1)

        source.simulateAuthorizationChange(to: .authorizedWhenInUse)
        await settleAuthorizationHop()
        #expect(source.startUpdatingLocationCalls == 1)
    }
}
