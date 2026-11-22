//
//  MapRegionRectTests.swift
//  OpenHikesTests
//
//  A region as the map rect every shown region becomes on its way to
//  MapKit (`MKCoordinateRegion.mapRect`): the rect between its corners, and
//  for a region across the antimeridian, such as the one *Offline Maps*
//  frames Fiji in, a rect running on past the world's east edge, which
//  MapKit reads as one across the 180th meridian. Its east corner taken on
//  its own lies past 180°, where `MKMapPoint` has no answer, and the rect
//  built from it covered the world.
//

import CoreLocation
import MapKit
@testable import OpenHikes
import OpenHikesData
import RealModule
import Testing

@MainActor
@Suite("Region as a map rect")
struct MapRegionRectTests {
    private static let world = MKMapSize.world.width

    private static func point(_ latitude: Double, _ longitude: Double) -> MKMapPoint {
        MKMapPoint(CLLocationCoordinate2D(latitude: latitude, longitude: longitude))
    }

    @Test("an ordinary region is the rect between its corners")
    func ordinaryRegion() {
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 47.63, longitude: 12.86),
            span: MKCoordinateSpan(latitudeDelta: 0.4, longitudeDelta: 0.6)
        )

        let rect = region.mapRect

        let northWest = Self.point(47.83, 12.56)
        let southEast = Self.point(47.43, 13.16)
        #expect(rect.minX.isApproximatelyEqual(to: northWest.x, absoluteTolerance: 1))
        #expect(rect.minY.isApproximatelyEqual(to: northWest.y, absoluteTolerance: 1))
        #expect(rect.maxX.isApproximatelyEqual(to: southEast.x, absoluteTolerance: 1))
        #expect(rect.maxY.isApproximatelyEqual(to: southEast.y, absoluteTolerance: 1))
        #expect(!rect.spans180thMeridian)
    }

    /// 174° E to 172° W, 14° across the date line, with its middle given
    /// either side of it.
    @Test("a region across the antimeridian runs on past the world's east edge", arguments: [-179.0, 181.0])
    func wrappedRegion(centerLongitude: Double) {
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: -17.5, longitude: centerLongitude),
            span: MKCoordinateSpan(latitudeDelta: 6, longitudeDelta: 14)
        )

        let rect = region.mapRect

        #expect(rect.spans180thMeridian)
        #expect(rect.minX.isApproximatelyEqual(to: Self.point(-14.5, 174).x, absoluteTolerance: 1))
        #expect(rect.width.isApproximatelyEqual(to: Self.world * 14 / 360, absoluteTolerance: 1))
        #expect(rect.minY.isApproximatelyEqual(to: Self.point(-14.5, 174).y, absoluteTolerance: 1))
        #expect(rect.maxY.isApproximatelyEqual(to: Self.point(-20.5, 174).y, absoluteTolerance: 1))

        let back = MKCoordinateRegion(rect)
        #expect(RouteGeometry.normalizedLongitudeDelta(back.center.longitude - 181)
            .isApproximatelyEqual(to: 0, absoluteTolerance: 1e-6))
        #expect(back.span.longitudeDelta.isApproximatelyEqual(to: 14, absoluteTolerance: 1e-6))
    }

    /// Cut to the world's width about its centre, which a west edge placed
    /// from the whole span would move to 38° W.
    @Test("a region as wide as the world, or wider, is the world's width round its centre")
    func worldWideRegion() {
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: -72, longitude: -3),
            span: MKCoordinateSpan(latitudeDelta: 25, longitudeDelta: 430)
        )

        let rect = region.mapRect

        #expect(rect.width.isApproximatelyEqual(to: Self.world, absoluteTolerance: 1))
        let back = MKCoordinateRegion(rect)
        #expect(RouteGeometry.normalizedLongitudeDelta(back.center.longitude + 3)
            .isApproximatelyEqual(to: 0, absoluteTolerance: 1e-6))
    }
}
