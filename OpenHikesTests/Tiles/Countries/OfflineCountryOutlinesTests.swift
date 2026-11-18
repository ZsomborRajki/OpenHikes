//
//  OfflineCountryOutlinesTests.swift
//  OpenHikesTests
//
//  The outlines *Offline Maps* draws on the map behind it: drawn only while
//  the screen holds the map, and a tap inside one choosing that country's
//  row. The map observes this object directly, so what it holds is what is
//  drawn.
//

import CoreLocation
import Foundation
import MapKit
@testable import OpenHikes
import RealModule
import Testing

@MainActor
@Suite("Offline country outlines")
struct OfflineCountryOutlinesTests {
    private let slovenia = OfflineCountryFixture.country(bytes: Data("SI".utf8))
    private let ljubljana = CLLocationCoordinate2D(latitude: 46.05, longitude: 14.5)

    @Test("the screen that holds the map draws, and a tap inside a country chooses it")
    func drawsAndChooses() {
        let outlines = OfflineCountryOutlines()
        var chosen: [String] = []
        let token = outlines.attach { chosen.append($0) }

        outlines.show([slovenia], installed: ["SI"], selected: nil, token: token)

        #expect(outlines.isActive)
        #expect(outlines.countries == [slovenia])
        #expect(outlines.installedIDs == ["SI"])
        #expect(outlines.select(at: ljubljana))
        #expect(!outlines.select(at: CLLocationCoordinate2D(latitude: 40, longitude: -3)))
        #expect(chosen == ["SI"])
    }

    /// The pop of an older copy of the screen arrives after the new copy has
    /// attached, and must not take the outlines off the map under it.
    @Test("an earlier screen's leaving does not take the map from the one after it")
    func staleDetach() {
        let outlines = OfflineCountryOutlines()
        let earlier = outlines.attach { _ in /* the earlier screen */ }
        let later = outlines.attach { _ in /* the later screen */ }
        outlines.show([slovenia], installed: [], selected: "SI", token: later)

        outlines.detach(token: earlier)
        outlines.show([], installed: [], selected: nil, token: earlier)
        #expect(outlines.isActive)
        #expect(outlines.countries == [slovenia])
        #expect(outlines.selectedID == "SI")

        outlines.detach(token: later)
        #expect(!outlines.isActive)
        #expect(outlines.countries.isEmpty)
        #expect(outlines.selectedID == nil)
        #expect(!outlines.select(at: ljubljana))
    }

    @Test("a country is framed whole, with room round it")
    func framing() {
        let region = OfflineCountryFixture.bounds.framingRegion
        let bounds = OfflineCountryFixture.bounds
        #expect(region.center.latitude.isApproximatelyEqual(to: 46.15, absoluteTolerance: 1e-9))
        #expect(region.center.longitude.isApproximatelyEqual(to: 14.95, absoluteTolerance: 1e-9))
        #expect(region.span.latitudeDelta > bounds.north - bounds.south)
        #expect(region.span.longitudeDelta > bounds.east - bounds.west)
    }
}
