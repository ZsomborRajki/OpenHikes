//
//  MapCoordinatorTests+SearchRegion.swift
//  OpenHikesTests
//
//  Place search was the one location question in the app that never said
//  where the hiker was. Neither `MKLocalSearchCompleter` nor the
//  `MKLocalSearch.Request` behind a typed Return carried a region, so both
//  fell back to MapKit's global default and a common name — "Blue Lake",
//  "Bergsee", "Ridge Trail" — could answer from the other side of the planet
//  and take the camera and the weather badge with it.
//
//  What is asserted here is the hand-over rather than MapKit's ranking: that
//  a settled region reaches ``SearchCompleter``, that it arrives from the same
//  coordinator callback the community list already learns the map moved from,
//  and that a settle which did not move the map is not forwarded — assigning
//  `region` while a query fragment is outstanding makes MapKit answer it
//  again. Whether the suggestions are *better* for it is a device pass; this
//  is the plumbing that makes them possible.
//

import CoreLocation
import Foundation
import MapKit
@testable import OpenHikes
import RealModule
import Testing

extension MapCoordinatorTests {
    private static func searchRegion(
        latitude: Double = 47.63,
        longitude: Double = 12.86,
        spanDegrees: Double = 0.2
    ) -> MKCoordinateRegion {
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            span: MKCoordinateSpan(latitudeDelta: spanDegrees, longitudeDelta: spanDegrees)
        )
    }

    @Test("a completer that has never been told where the map is has no region")
    func searchCompleterStartsWithoutARegion() {
        #expect(
            SearchCompleter().region == nil,
            "a region invented before the map has settled would bias the first query to nowhere"
        )
    }

    @Test("a settled region reaches the completer")
    func searchCompleterTakesTheSettledRegion() throws {
        let completer = SearchCompleter()
        let region = Self.searchRegion()
        completer.regionDidSettle(region)

        let stored = try #require(completer.region)
        #expect(stored.center.latitude == region.center.latitude)
        #expect(stored.center.longitude == region.center.longitude)
        #expect(stored.span.latitudeDelta == region.span.latitudeDelta)
    }

    /// The map moving again replaces the bias rather than keeping the first
    /// answer, which is the difference between following the hiker and
    /// following wherever they happened to open the app.
    @Test("a second settle replaces the first")
    func searchCompleterFollowsTheMap() throws {
        let completer = SearchCompleter()
        completer.regionDidSettle(Self.searchRegion())
        completer.regionDidSettle(Self.searchRegion(latitude: 48.03, longitude: 11.5))

        let stored = try #require(completer.region)
        #expect(stored.center.latitude == 48.03)
        #expect(stored.center.longitude == 11.5)
    }

    /// The same call site that tells the community list the map moved. It is
    /// deliberately the *settled* region — `mapViewDidChangeVisibleRegion`
    /// fires per frame through a pan — and this asserts the completer is on
    /// it, not that MapKit chose the moment.
    @Test("the coordinator hands the settled region to place search")
    func settledRegionReachesPlaceSearch() throws {
        #if os(iOS)
        let completer = SearchCompleter()
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(searchCompleter: completer), coordinator)
        defer { detach(map) }

        map.region = Self.searchRegion(latitude: 47.63, longitude: 12.86, spanDegrees: 0.1)
        coordinator.mapView(map, regionDidChangeAnimated: false)

        let stored = try #require(
            completer.region,
            "the settle that feeds the community list must feed place search too"
        )
        #expect(stored.center.latitude.isApproximatelyEqual(to: map.region.center.latitude, absoluteTolerance: 0.001))
        #expect(stored.center.longitude.isApproximatelyEqual(to: map.region.center.longitude, absoluteTolerance: 0.001))
        #endif
    }
}
