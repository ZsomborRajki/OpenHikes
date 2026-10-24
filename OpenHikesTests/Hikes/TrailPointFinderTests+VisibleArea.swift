//
//  TrailPointFinderTests+VisibleArea.swift
//  OpenHikesTests
//
//  What the finder takes from a settled map: the rectangle on screen, and the
//  ceiling that map is held to.
//
//  Beside the suite for length. Which region the map hands over is the
//  coordinator's half — see `MapCoordinatorTests+PlaceSearchRegion.swift`.
//  This is the finder's, asserted on the box a search asks Overpass about,
//  because the square around a circle and the rectangle inside it both come
//  back as a plausible list of places.
//

import CoreLocation
import Foundation
import MapKit
@testable import OpenHikes
import OpenHikesData
import RealModule
import Testing

extension TrailPointFinderTests {
    /// The figures the regions below are built from, named so they read as
    /// what they are.
    private enum Visible {
        /// Berchtesgaden.
        static let latitude = 47.63
        static let longitude = 12.86
        /// A map above a half-height sheet, wider than it is tall, so the
        /// square around its circle and the rectangle itself differ in both
        /// directions.
        static let latitudeSpan = 0.03
        static let longitudeSpan = 0.06
        /// Under a kilometre across, so a north-to-south side is the longer.
        static let narrowSpan = 0.01
    }

    private static let visibleRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: Visible.latitude, longitude: Visible.longitude),
        span: MKCoordinateSpan(latitudeDelta: Visible.latitudeSpan, longitudeDelta: Visible.longitudeSpan)
    )

    /// A map at `visibleRegion`'s middle whose longer side, north to south, is
    /// `meters` long.
    private static func region(northToSouth meters: Double) -> MKCoordinateRegion {
        MKCoordinateRegion(
            center: visibleRegion.center,
            span: MKCoordinateSpan(
                latitudeDelta: meters / RouteGeometry.metersPerDegreeLatitude,
                longitudeDelta: Visible.narrowSpan
            )
        )
    }

    /// The square around the circle was the square around the whole map, as
    /// wide as the screen is tall and mostly under the sheet.
    @Test("a settled map's rectangle is what Overpass is asked about, not the square around its circle")
    func theVisibleRectangleIsTheBox() throws {
        let finder = TrailPointFinder()
        let region = Self.visibleRegion

        finder.regionDidSettle(region)

        let area = try #require(finder.searchableArea)
        let boxes = TrailPointQuery.searchBoxes(for: area)
        #expect(boxes.count == 1)
        let box = try #require(boxes.first)
        let halfHeight = region.span.latitudeDelta / 2
        let halfWidth = region.span.longitudeDelta / 2
        let tolerance = 1e-9
        #expect(box.south.isApproximatelyEqual(to: region.center.latitude - halfHeight, absoluteTolerance: tolerance))
        #expect(box.north.isApproximatelyEqual(to: region.center.latitude + halfHeight, absoluteTolerance: tolerance))
        #expect(box.west.isApproximatelyEqual(to: region.center.longitude - halfWidth, absoluteTolerance: tolerance))
        #expect(box.east.isApproximatelyEqual(to: region.center.longitude + halfWidth, absoluteTolerance: tolerance))
    }

    /// Twice the radius, because the radius is half the longer side — so the
    /// box at the ceiling is never more than the 20 × 20 km the ceiling was
    /// measured for.
    @Test("the ceiling is the longer side of the map on screen, at twice the places' radius")
    func theCeilingIsTheLongerSide() {
        let longest = 2 * TrailPointQuery.maximumRadiusMeters
        let center = Self.visibleRegion.center

        #expect(TrailPointFinder.isWithinCeiling(Self.region(northToSouth: longest * 0.99)))
        #expect(!TrailPointFinder.isWithinCeiling(Self.region(northToSouth: longest * 1.01)))
        #expect(
            !TrailPointFinder.isWithinCeiling(
                MKCoordinateRegion(center: center, span: MKCoordinateSpan(latitudeDelta: .nan, longitudeDelta: .nan))
            ),
            "a map whose size is not a number is refused rather than searched"
        )
        #expect(
            !TrailPointFinder.isWithinCeiling(
                MKCoordinateRegion(center: center, span: MKCoordinateSpan(latitudeDelta: 0, longitudeDelta: 0))
            ),
            "and so is a map with no size"
        )
    }
}
