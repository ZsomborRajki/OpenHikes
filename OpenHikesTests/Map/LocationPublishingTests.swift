//
//  LocationPublishingTests.swift
//  OpenHikesTests
//
//  "Location publishing", split out of RenderIsolationTests.swift so that a
//  file declares one @Suite. That file's header still holds the context the
//  two share.
//

import CoreLocation
import Foundation
import MapKit
@testable import OpenHikes
import SwiftUI
import Testing

@Suite("Location publishing")
struct LocationPublishingTests {
    private func location(
        horizontalAccuracy: CLLocationAccuracy,
        latitude: Double = 47.63,
        longitude: Double = 12.86,
        timestamp: Date = .now
    ) -> CLLocation {
        CLLocation(
            coordinate: .init(latitude: latitude, longitude: longitude),
            altitude: 0,
            horizontalAccuracy: horizontalAccuracy,
            verticalAccuracy: -1,
            course: -1,
            speed: -1,
            timestamp: timestamp
        )
    }

    @Test("reduced-accuracy fixes remain available for coarse features")
    func reducedAccuracyIsPublishedButNotRouteMatched() async {
        let manager = LocationManager()
        let approximate = location(horizontalAccuracy: 1500)

        manager.locationManager(CLLocationManager(), didUpdateLocations: [approximate])
        await Task.yield()

        #expect(manager.coordinate?.latitude == approximate.coordinate.latitude)
        #expect(manager.coordinate?.longitude == approximate.coordinate.longitude)
        #expect(
            manager.routeFix(
                maximumHorizontalAccuracy: RouteProfile.followMatchThresholdMeters
            ) == nil
        )
    }

    @Test("invalid and stale fixes are rejected")
    func invalidAndStaleFixesAreRejected() async {
        let staleManager = LocationManager()
        let stale = location(
            horizontalAccuracy: 10,
            timestamp: .now.addingTimeInterval(-(LocationFixPolicy.foregroundMaximumAge + 1))
        )
        staleManager.locationManager(CLLocationManager(), didUpdateLocations: [stale])
        await Task.yield()

        let invalidManager = LocationManager()
        let invalid = location(horizontalAccuracy: -1)
        invalidManager.locationManager(CLLocationManager(), didUpdateLocations: [invalid])
        await Task.yield()

        #expect(staleManager.coordinate == nil)
        #expect(invalidManager.coordinate == nil)
    }

    /// A fix's course is what tells auto-follow which leg of an out-and-back
    /// a hiker is on, so what counts as a *usable* course decides whether
    /// that works at all — and both the foreground and the background feed
    /// ask this one question, so they can't drift apart.
    @Test("only a fix from someone actually moving carries a usable course")
    func courseNeedsMovement() {
        func fix(
            course: CLLocationDirection,
            courseAccuracy: CLLocationDirectionAccuracy,
            speed: CLLocationSpeed
        ) -> CLLocation {
            CLLocation(
                coordinate: .init(latitude: 47.63, longitude: 12.86),
                altitude: 0,
                horizontalAccuracy: 10,
                verticalAccuracy: -1,
                course: course,
                courseAccuracy: courseAccuracy,
                speed: speed,
                speedAccuracy: -1,
                timestamp: .now
            )
        }

        #expect(
            LocationFixPolicy.course(of: fix(course: 180, courseAccuracy: 10, speed: 1.4)) == 180,
            "walking, and the receiver is sure which way"
        )

        // Standing at a viewpoint: the reported course wanders and means nothing.
        #expect(LocationFixPolicy.course(of: fix(course: 180, courseAccuracy: 10, speed: 0)) == nil)
        // The receiver saying it doesn't know.
        #expect(LocationFixPolicy.course(of: fix(course: -1, courseAccuracy: -1, speed: 1.4)) == nil)
        // …or knowing so vaguely that it can't distinguish out from back.
        #expect(LocationFixPolicy.course(of: fix(course: 180, courseAccuracy: 90, speed: 1.4)) == nil)
        // No uncertainty reported at all is absence of evidence, not evidence
        // of a bad course — simulated locations arrive exactly like this.
        #expect(LocationFixPolicy.course(of: fix(course: 180, courseAccuracy: -1, speed: 1.4)) == 180)
    }

    /// Position and course have to describe the same instant, or a hiker
    /// gets matched against the way they were going somewhere else.
    @Test("a route fix carries the course of the fix it came from")
    func routeFixCarriesItsCourse() async throws {
        let manager = LocationManager()
        let walking = CLLocation(
            coordinate: .init(latitude: 47.63, longitude: 12.86),
            altitude: 0,
            horizontalAccuracy: 10,
            verticalAccuracy: -1,
            course: 42,
            courseAccuracy: 5,
            speed: 1.4,
            speedAccuracy: -1,
            timestamp: .now
        )
        let tolerance = RouteProfile.followMatchThresholdMeters
        manager.locationManager(CLLocationManager(), didUpdateLocations: [walking])
        await settleDelegateHop(until: "the delivered fix to reach the manager") {
            manager.routeFix(maximumHorizontalAccuracy: tolerance) != nil
        }
        let fix = try #require(manager.routeFix(maximumHorizontalAccuracy: tolerance))
        #expect(fix.coordinate.latitude == 47.63)
        #expect(fix.course == 42)
    }

    /// CoreLocation can deliver far more often than once a second; the
    /// throttle is what keeps that off every observer downstream.
    ///
    /// Asserted on the published value rather than on a notification count.
    /// `ObservationCounter` re-arms through a `Task`, so ten writes in one
    /// runloop turn consume the single armed registration on the first and
    /// reach the counter exactly once whether the throttle exists or not —
    /// measured, by deleting `minimumPublishInterval` and watching this stay
    /// green. `coordinate` is the only witness that can tell the two apart:
    /// throttled it holds the *first* fix of the burst, unthrottled the last.
    @Test("a burst of fixes publishes once")
    func burstIsThrottled() {
        let clock = TestClock()
        let manager = LocationManager(clock: clock.read)

        for step in 0..<10 {
            manager.locationManager(
                CLLocationManager(),
                didUpdateLocations: [CLLocation(latitude: 47.63 + Double(step) * 1e-4, longitude: 12.86)]
            )
        }
        // `onMainActor` runs the delegate body synchronously here, so there is
        // a value to read without settling for one.
        #expect(manager.coordinate?.latitude == 47.63, "the nine behind the first are inside the window")

        // Past `minimumPublishInterval`, which is private; the sibling tests
        // step the same 1.1s over it.
        clock.advance(by: 1.1)
        manager.locationManager(
            CLLocationManager(),
            didUpdateLocations: [CLLocation(latitude: 47.64, longitude: 12.86)]
        )
        #expect(manager.coordinate?.latitude == 47.64, "and the window reopens rather than latching shut")
    }

    /// A hiker who has stopped — at a viewpoint, a hut, a photo — still gets
    /// a fix every second. Republishing each one as a new value would wake the
    /// map coordinator, which re-registers its observation through a `Task`
    /// hop, once a second for as long as the app is open.
    ///
    /// Nothing downstream needs that heartbeat: auto-follow and the weather
    /// poll both drive off `fixes`, which only emits when `coordinate`
    /// changes, and the map only uses it to center on the very first fix. So
    /// an unchanged fix has nobody to tell.
    @Test("an unchanged fix isn't republished")
    func unchangedFixIsNotRepublished() async {
        let clock = TestClock()
        let manager = LocationManager(clock: clock.read)
        let counter = ObservationCounter { _ = manager.coordinate }
        await counter.settle()

        let stationary = CLLocation(latitude: 47.6300, longitude: 12.8600)
        manager.locationManager(CLLocationManager(), didUpdateLocations: [stationary])
        await counter.settle()
        #expect(counter.count == 1, "precondition: the first fix is published")

        // Past the 1 s throttle, so this one is not being dropped for timing —
        // it's the same place.
        clock.advance(by: 1.1)
        manager.locationManager(
            CLLocationManager(),
            didUpdateLocations: [
                CLLocation(latitude: stationary.coordinate.latitude, longitude: stationary.coordinate.longitude)
            ]
        )
        await counter.settle()
        #expect(counter.count == 1, "standing still should not wake the map's observation every second")
    }

    /// …while actually moving must still publish, or auto-follow stops.
    @Test("a fix that moved is published")
    func movedFixIsPublished() async {
        let clock = TestClock()
        let manager = LocationManager(clock: clock.read)
        let counter = ObservationCounter { _ = manager.coordinate }
        await counter.settle()

        manager.locationManager(
            CLLocationManager(),
            didUpdateLocations: [CLLocation(latitude: 47.6300, longitude: 12.8600)]
        )
        await counter.settle()
        clock.advance(by: 1.1)
        manager.locationManager(
            CLLocationManager(),
            didUpdateLocations: [CLLocation(latitude: 47.6305, longitude: 12.8600)]
        )
        await counter.settle()

        #expect(counter.count == 2)
        #expect(manager.coordinate?.latitude == 47.6305)
    }
}
