//
//  DormantLocationSourceTests.swift
//  OpenHikesTests
//
//  "Dormant location source", split out of
//  LocationManagerConfigurationTests.swift so that a file declares one
//  @Suite.
//

import CoreLocation
@testable import OpenHikes
import Testing

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
