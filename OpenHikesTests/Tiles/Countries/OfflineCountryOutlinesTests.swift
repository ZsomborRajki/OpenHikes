//
//  OfflineCountryOutlinesTests.swift
//  OpenHikesTests
//
//  The outlines *Offline Maps* draws on the map behind it: drawn only while
//  the screen holds the map, and a tap inside one choosing that country's
//  row. The map observes this object directly, so what it holds is what is
//  drawn. And the region a row's tap frames: the area's outline, the short
//  way round, so an area across the antimeridian is not framed round the
//  world.
//

import CoreLocation
import Foundation
import MapKit
@testable import OpenHikes
import OpenHikesData
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
        let region = slovenia.framingRegion
        let bounds = OfflineCountryFixture.bounds
        let padding = OfflineCountryManifest.Country.framePadding
        #expect(region.center.latitude.isApproximatelyEqual(to: 46.15, absoluteTolerance: 1e-9))
        #expect(region.center.longitude.isApproximatelyEqual(to: 14.95, absoluteTolerance: 1e-9))
        #expect(region.span.latitudeDelta.isApproximatelyEqual(
            to: (bounds.north - bounds.south) * padding, absoluteTolerance: 1e-9
        ))
        #expect(region.span.longitudeDelta.isApproximatelyEqual(
            to: (bounds.east - bounds.west) * padding, absoluteTolerance: 1e-9
        ))
    }

    /// Its bounds' middle is 0°, the far side of the world from it, and
    /// their width all of it.
    @Test("an area cut at the antimeridian is framed across it, not round the world")
    func framingAcrossTheAntimeridian() {
        let region = OfflineCountryFixture.dateLineCountry(bytes: Data("FJ".utf8)).framingRegion
        let padding = OfflineCountryManifest.Country.framePadding
        #expect(region.center.longitude.isApproximatelyEqual(to: 179.25, absoluteTolerance: 1e-9))
        #expect(region.span.longitudeDelta.isApproximatelyEqual(to: 4.5 * padding, absoluteTolerance: 1e-9))
        #expect(region.center.latitude.isApproximatelyEqual(to: -17.5, absoluteTolerance: 1e-9))
        #expect(region.span.latitudeDelta.isApproximatelyEqual(to: 3 * padding, absoluteTolerance: 1e-9))
    }

    /// The areas whose bounds go round the world in the server's own list,
    /// read from the showcase copy of it.
    @Test("Fiji, Chukotka and Alaska are each framed round themselves", arguments: ["FJ", "RU-CHU", "US-AK"])
    func framingTheListsDateLineAreas(id: String) async throws {
        let area = try #require(try await Self.showcase().first { $0.id == id })
        #expect(area.bounds.east - area.bounds.west > 359, "precondition: bounds round the world")

        let region = area.framingRegion

        #expect(region.span.longitudeDelta < 90, "a frame round the area, not round the world")
        #expect(Self.region(region, holdsTheOutlineOf: area))
    }

    @Test("every listed area is framed round its whole outline, and no wider than its bounds")
    func framingEveryListedArea() async throws {
        let listed = try await Self.showcase()
        #expect(listed.count > 300, "precondition: the whole list")
        let padding = OfflineCountryManifest.Country.framePadding

        let cutOff = listed.filter { !Self.region($0.framingRegion, holdsTheOutlineOf: $0) }
        let wider = listed.filter { area in
            area.framingRegion.span.longitudeDelta > (area.bounds.east - area.bounds.west) * padding + 1e-9
        }

        #expect(cutOff.map(\.id).isEmpty)
        #expect(wider.map(\.id).isEmpty)
    }

    private static func showcase() async throws -> [OfflineCountryManifest.Country] {
        try await SeededOfflineCountryServer(scenario: .showcase).manifest().countries
    }

    /// Whether every vertex of the area's outline is inside `region`, its
    /// longitude measured from the middle the short way round.
    private static func region(
        _ region: MKCoordinateRegion,
        holdsTheOutlineOf area: OfflineCountryManifest.Country
    ) -> Bool {
        area.outline.joined().allSatisfy { vertex in
            let east = RouteGeometry.normalizedLongitudeDelta(vertex[0] - region.center.longitude)
            return abs(east) <= region.span.longitudeDelta / 2 + 1e-9
                && abs(vertex[1] - region.center.latitude) <= region.span.latitudeDelta / 2 + 1e-9
        }
    }
}
