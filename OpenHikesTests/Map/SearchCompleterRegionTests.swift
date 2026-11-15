//
//  SearchCompleterRegionTests.swift
//  OpenHikesTests
//
//  Which settles ``SearchCompleter`` passes on to MapKit. Assigning `region`
//  while a query fragment is outstanding makes MapKit answer it again, so a
//  settle that did not move the map is not forwarded — and floating-point
//  drift in the last decimal places is not a move. Pinned here is what is: a
//  change of more than a millionth of a degree in any one of the region's
//  four numbers, measured against the region MapKit was last given.
//
//  Driven through ``RecordingCompleter``, which counts the assignments, so
//  the decision is read where it lands rather than from the private helper
//  that makes it. ``MapCoordinatorTests`` covers the hand-over from the map.
//

import CoreLocation
import MapKit
@testable import OpenHikes
import Testing

@MainActor
@Suite("Search completer region")
struct SearchCompleterRegionTests {
    /// The four numbers a region is compared on, each moved alone so that one
    /// left out of the comparison would show.
    enum Component: String, CaseIterable, Sendable {
        case latitude = "latitude"
        case longitude = "longitude"
        case latitudeSpan = "latitude span"
        case longitudeSpan = "longitude span"

        func moving(_ region: MKCoordinateRegion, by degrees: Double) -> MKCoordinateRegion {
            var region = region
            switch self {
            case .latitude: region.center.latitude += degrees
            case .longitude: region.center.longitude += degrees
            case .latitudeSpan: region.span.latitudeDelta += degrees
            case .longitudeSpan: region.span.longitudeDelta += degrees
            }
            return region
        }
    }

    /// A millionth of a degree, about 11 cm of latitude. ``SearchCompleter``
    /// spells its own; this is the figure it is held to.
    private static let tolerance = 1e-6

    private static let settled = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 47.63, longitude: 12.86),
        span: MKCoordinateSpan(latitudeDelta: 0.2, longitudeDelta: 0.2)
    )

    private let recorder = RecordingCompleter()
    private let completer: SearchCompleter

    init() {
        completer = SearchCompleter(completer: recorder)
    }

    @Test("settling again where the map already is reaches MapKit once")
    func repeatedSettleIsForwardedOnce() {
        for _ in 0..<3 {
            completer.regionDidSettle(Self.settled)
        }

        #expect(recorder.regionsAssigned == 1)
    }

    @Test("drift inside the tolerance is not a move", arguments: Component.allCases)
    func driftIsNotForwarded(component: Component) {
        completer.regionDidSettle(Self.settled)
        completer.regionDidSettle(component.moving(Self.settled, by: Self.tolerance * 0.9))
        completer.regionDidSettle(component.moving(Self.settled, by: -Self.tolerance * 0.9))

        #expect(recorder.regionsAssigned == 1)
    }

    @Test("a change just past the tolerance is forwarded", arguments: Component.allCases)
    func moveIsForwarded(component: Component) {
        completer.regionDidSettle(Self.settled)
        let moved = component.moving(Self.settled, by: Self.tolerance * 1.1)
        completer.regionDidSettle(moved)

        #expect(recorder.regionsAssigned == 2)
        #expect(recorder.region.center.latitude == moved.center.latitude)
        #expect(recorder.region.center.longitude == moved.center.longitude)
        #expect(recorder.region.span.latitudeDelta == moved.span.latitudeDelta)
        #expect(recorder.region.span.longitudeDelta == moved.span.longitudeDelta)
    }

    /// Drift is measured from the region MapKit was last given rather than
    /// from the previous settle, so a map nudged a little at a time still
    /// arrives once the nudges add up.
    @Test("drift that adds up to a move is forwarded")
    func accumulatedDriftIsForwarded() {
        completer.regionDidSettle(Self.settled)
        for step in 1...3 {
            let nudge = Self.tolerance * 0.4 * Double(step)
            completer.regionDidSettle(Component.latitude.moving(Self.settled, by: nudge))
        }

        #expect(recorder.regionsAssigned == 2, "0.4 and 0.8 of the tolerance are drift, 1.2 is a move")
    }
}
