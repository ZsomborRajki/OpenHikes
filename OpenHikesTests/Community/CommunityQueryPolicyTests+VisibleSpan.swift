//
//  CommunityQueryPolicyTests+VisibleSpan.swift
//  OpenHikesTests
//
//  The two shapes one offer carries.
//
//  The radius was the whole of an area until the map started handing over
//  the rectangle it shows, and the floor on it is CloudKit's — it cannot tell
//  distances under ten kilometres apart. So the offer keeps that circle for
//  the published half and carries the rectangle beside it, unfloored, for
//  OpenStreetMap. Each half of that is pinned here because each one, dropped,
//  leaves a list that looks right: the floor gone is a CloudKit question
//  narrower than its own answer, and the rectangle gone is the twenty-kilometre
//  square this replaced.
//

import Foundation
import MapKit
@testable import OpenHikes
import OpenHikesData
import Testing

extension CommunityQueryPolicyTests {
    /// A valley's worth of map above a half-height sheet: 2 km tall and
    /// 3 km wide, well under the floor.
    private enum Valley {
        static let latitude = 47.63
        static let longitude = 12.86
        static let latitudeDelta = 0.018
        static let longitudeDelta = 0.04
    }

    private static let valley = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: Valley.latitude, longitude: Valley.longitude),
        span: MKCoordinateSpan(latitudeDelta: Valley.latitudeDelta, longitudeDelta: Valley.longitudeDelta)
    )

    @Test("an offer carries the rectangle on screen, unfloored")
    func theOfferCarriesTheVisibleRectangle() throws {
        var policy = CommunityQueryPolicy()
        policy.startBrowsing()

        guard case .offer(let area) = policy.action(for: Self.valley) else {
            Issue.record("a valley is a question")
            return
        }

        let span = try #require(area.visibleSpan)
        #expect(span.latitudeDelta == Self.valley.span.latitudeDelta)
        #expect(span.longitudeDelta == Self.valley.span.longitudeDelta)
        #expect(area.latitude == Self.valley.center.latitude)
        #expect(area.longitude == Self.valley.center.longitude)
    }

    @Test("the circle beside it keeps CloudKit's floor")
    func theCircleKeepsItsFloor() {
        var policy = CommunityQueryPolicy()
        policy.startBrowsing()

        guard case .offer(let area) = policy.action(for: Self.valley) else {
            Issue.record("a valley is a question")
            return
        }

        #expect(area.radiusMeters == CommunityQueryPolicy.minimumRadiusMeters)
    }

    /// What a refused search draws from the device is what is *in* the area,
    /// and an offer's circle is CloudKit's floor rather than the map: a point
    /// a few kilometres off a valley's rectangle is inside it. See
    /// ``CommunitySearchArea/contains(_:)``.
    @Test("an offer's rectangle, not its floored circle, says what is in it")
    func theRectangleSaysWhatIsInIt() {
        var policy = CommunityQueryPolicy()
        policy.startBrowsing()

        guard case .offer(let area) = policy.action(for: Self.valley) else {
            Issue.record("a valley is a question")
            return
        }
        let inside = CLLocationCoordinate2D(latitude: Valley.latitude + 0.008, longitude: Valley.longitude - 0.019)
        let southOfIt = CLLocationCoordinate2D(latitude: Valley.latitude - 0.03, longitude: Valley.longitude)

        #expect(area.contains(inside))
        #expect(!area.contains(southOfIt), "three kilometres south is in the circle and off the map")
        #expect(RouteGeometry.distanceMeters(from: area.coordinate, to: southOfIt) < area.radiusMeters)
    }

    /// A view across the date line is a narrow rectangle with the line through
    /// it, and both sides of the line are on screen.
    @Test("a rectangle across the date line holds both sides of it")
    func aRectangleAcrossTheDateLine() {
        let area = CommunitySearchArea(
            coordinate: CLLocationCoordinate2D(latitude: -16.8, longitude: 179.99),
            radiusMeters: CommunityQueryPolicy.minimumRadiusMeters,
            visibleSpan: CommunitySearchArea.Span(latitudeDelta: 0.02, longitudeDelta: 0.04)
        )

        #expect(area.contains(CLLocationCoordinate2D(latitude: -16.8, longitude: -179.995)))
        #expect(area.contains(CLLocationCoordinate2D(latitude: -16.8, longitude: 179.975)))
        #expect(!area.contains(CLLocationCoordinate2D(latitude: -16.8, longitude: -179.97)))
    }

    /// An area that is only a circle — the trail maker's, a stretch of a
    /// route — keeps answering by its radius.
    @Test("an area without a rectangle is its circle")
    func aCircleIsItsRadius() {
        let area = CommunitySearchArea(
            coordinate: CLLocationCoordinate2D(latitude: Valley.latitude, longitude: Valley.longitude),
            radiusMeters: CommunityQueryPolicy.minimumRadiusMeters
        )

        #expect(area.contains(CLLocationCoordinate2D(latitude: Valley.latitude - 0.08, longitude: Valley.longitude)))
        #expect(!area.contains(CLLocationCoordinate2D(latitude: Valley.latitude - 0.1, longitude: Valley.longitude)))
    }
}
