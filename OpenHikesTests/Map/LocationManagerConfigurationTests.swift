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

    /// No settle between the callback and the assertion: `onMainActor`
    /// delivers synchronously when the caller is already on the main actor,
    /// which a main-actor-isolated test always is, so the whole authorization
    /// branch has run by the time `simulateAuthorizationChange` returns.
    @Test("authorization changes start updates only after start was requested")
    func authorizationCallbackHonorsStartLifecycle() {
        source.simulateAuthorizationChange(to: .authorizedWhenInUse)
        #expect(source.startUpdatingLocationCalls == 0)

        source.foregroundAuthorizationStatus = .notDetermined
        manager.start()
        #expect(source.requestWhenInUseAuthorizationCalls == 1)

        source.simulateAuthorizationChange(to: .authorizedWhenInUse)
        #expect(source.startUpdatingLocationCalls == 1)
    }

    /// What ``DormantLocationSource`` relies on to be inert rather than merely
    /// idle: it answers `.denied`, and a denied source is the one case where
    /// `start()` neither asks for anything nor turns anything on. Without this
    /// branch holding, a launch that composed the stand-in would still put an
    /// authorization alert on screen.
    @Test("start asks for nothing and begins nothing when access is denied")
    func startStaysInertWhenDenied() {
        source.foregroundAuthorizationStatus = .denied

        manager.start()

        #expect(source.requestWhenInUseAuthorizationCalls == 0)
        #expect(source.startUpdatingLocationCalls == 0)
    }
}

/// The stand-in every launch without live location composes in place of
/// `CLLocationManager` — see ``AppLaunchEnvironment/usesLiveLocation``.
@Suite("Dormant location source")
struct DormantLocationSourceTests {
    @Test("reports no foreground access, so a manager built on it starts nothing")
    func foregroundStaysDenied() {
        let source = DormantLocationSource()
        let manager = LocationManager(manager: source)

        manager.start()

        #expect(source.foregroundAuthorizationStatus == .denied)
        #expect(manager.coordinate == nil)
        #expect(manager.routeFix(maximumHorizontalAccuracy: .greatestFiniteMagnitude) == nil)
    }

    /// Both answers false, which is what the tracker's own start path checks
    /// before it arms significant-change monitoring or asks for Always: with
    /// nothing to ask and nothing granted, a re-arm on launch does nothing.
    @Test("reports no background access and refuses to be asked for it")
    func backgroundStaysUnauthorized() {
        let source = DormantLocationSource()

        #expect(!source.isAlwaysAuthorized)
        #expect(!source.canRequestAlwaysAccess)
    }

    /// A real `CLLocationManager` holds its delegate weakly; a stand-in that
    /// did not would keep every `LocationManager` composed against it alive,
    /// since the manager owns the source and the source is handed the manager.
    @Test("holds its delegates weakly, as the manager it stands in for does")
    func doesNotRetainItsDelegates() {
        let source = DormantLocationSource()
        do {
            let manager = LocationManager(manager: source)
            #expect(source.foregroundDelegate === manager)
        }

        #expect(source.foregroundDelegate == nil)
    }
}
