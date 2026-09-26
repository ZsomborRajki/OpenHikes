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
import OpenHikesData
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

    /// The low-frequency half of the fix, for a body that only needs to know
    /// whether to *offer* something at the hiker's position — see the maker's
    /// *My Location* rows. A rejected fix is not a fix.
    @Test("there is a fix only once a fix has been published")
    func hasFixFollowsTheFirstPublishedFix() async {
        let manager = LocationManager()
        #expect(!manager.hasFix)

        manager.locationManager(CLLocationManager(), didUpdateLocations: [location(horizontalAccuracy: -1)])
        await Task.yield()
        #expect(!manager.hasFix)

        manager.locationManager(CLLocationManager(), didUpdateLocations: [location(horizontalAccuracy: 10)])
        await Task.yield()
        #expect(manager.hasFix)
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

    /// Every accepted fix is published, so a burst — the first few of a
    /// launch, say, arriving as the receiver settles — leaves `coordinate` on
    /// its last, the freshest, rather than on whichever arrived first.
    ///
    /// Read off the published value rather than a notification count:
    /// `ObservationCounter` re-arms through a `Task`, so ten writes in one
    /// runloop turn reach it once however many of them were published.
    @Test("a burst of fixes publishes its latest")
    func burstPublishesItsLatestFix() {
        let manager = LocationManager()
        let burst = (0..<10).map { step in
            CLLocation(latitude: 47.63 + Double(step) * 1e-4, longitude: 12.86)
        }

        for fix in burst {
            manager.locationManager(CLLocationManager(), didUpdateLocations: [fix])
        }

        // `onMainActor` runs the delegate body synchronously here, so there is
        // a value to read without settling for one.
        #expect(manager.coordinate?.latitude == burst.last?.coordinate.latitude)
    }

    /// Core Location can hand over the same place twice — it sends a fresh
    /// first fix every time the feed resumes, and that fix can be where the
    /// last one was. Republishing it as a new value would wake the map
    /// coordinator, which re-registers its observation through a `Task` hop,
    /// and auto-follow, which would re-derive a match it already has.
    @Test("an unchanged fix isn't republished")
    func unchangedFixIsNotRepublished() async {
        let manager = LocationManager()
        let counter = ObservationCounter { _ = manager.coordinate }
        await counter.settle()

        let stationary = CLLocation(latitude: 47.6300, longitude: 12.8600)
        manager.locationManager(CLLocationManager(), didUpdateLocations: [stationary])
        await counter.settle()
        #expect(counter.count == 1, "precondition: the first fix is published")

        manager.locationManager(
            CLLocationManager(),
            didUpdateLocations: [
                CLLocation(latitude: stationary.coordinate.latitude, longitude: stationary.coordinate.longitude)
            ]
        )
        await counter.settle()
        #expect(counter.count == 1, "the same place again should not wake the map's observation")
    }

    /// …while actually moving must still publish, or auto-follow stops.
    @Test("a fix that moved is published")
    func movedFixIsPublished() async {
        let manager = LocationManager()
        let counter = ObservationCounter { _ = manager.coordinate }
        await counter.settle()

        manager.locationManager(
            CLLocationManager(),
            didUpdateLocations: [CLLocation(latitude: 47.6300, longitude: 12.8600)]
        )
        await counter.settle()
        manager.locationManager(
            CLLocationManager(),
            didUpdateLocations: [CLLocation(latitude: 47.6305, longitude: 12.8600)]
        )
        await counter.settle()

        #expect(counter.count == 2)
        #expect(manager.coordinate?.latitude == 47.6305)
    }
}
