//
//  OfflineCountriesListingTests.swift
//  OpenHikesTests
//
//  How *Offline Maps* lists the areas: a country too big for one download
//  is one line of *All Countries* that holds all its regions, a region is
//  named in the app's language and, outside its country's line, with its
//  country, and a region chosen on the map opens its country's line.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import RealModule
import Testing

// swiftlint:disable no_magic_numbers

@MainActor
@Suite("Offline countries: listing")
struct OfflineCountriesListingTests {
    private static func region(
        _ id: String,
        _ english: String,
        german: String? = nil
    ) -> OfflineCountryManifest.Country {
        var names = ["en": english]
        if let german { names["de"] = german }
        return OfflineCountryFixture.country(bytes: Data(id.utf8), id: id, group: String(id.prefix(2)), names: names)
    }

    private let colorado = region("US-CO", "Colorado")
    private let california = region("US-CA", "California", german: "Kalifornien")
    private let slovenia = OfflineCountryFixture.country(bytes: Data("SI".utf8))

    @Test("a split country is one line of All Countries, with all its regions under it by name")
    func groups() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let harness = await OfflineCountryHarness.make(in: directory, offering: [colorado, slovenia, california])
            let sections = harness.countries.sections(of: harness.countries.listed, near: nil)

            #expect(sections.rest == [.area(slovenia), .group(id: "US", regions: [california, colorado])])
        }
    }

    /// The line under the country is the whole directory of its regions, so
    /// a region near the hiker is under it too, as well as in *Nearby*.
    @Test("a region near the hiker is in Nearby and still under its country")
    func regionNearby() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            var near = colorado
            near.bounds = OfflineCountryManifest.Bounds(west: -109, south: 37, east: -102, north: 41)
            near.outline = OfflineCountryFixture.outline(of: near.bounds)
            let harness = await OfflineCountryHarness.make(in: directory, offering: [near, california])
            let sections = harness.countries.sections(
                of: harness.countries.listed,
                near: CLLocationCoordinate2D(latitude: 39.7, longitude: -105.0)
            )

            #expect(sections.nearby == [near])
            #expect(sections.rest == [.group(id: "US", regions: [california, near])])
            let nearTarget = sections.scrollTarget(for: "US-CO")
            #expect(nearTarget.rowID == "US-CO")
            #expect(nearTarget.opening == nil)
            let groupTarget = sections.scrollTarget(for: "US-CA")
            #expect(groupTarget.rowID == OfflineCountrySections.groupRowID("US-CA"))
            #expect(groupTarget.opening == "US")
        }
    }

    /// Alaska as Natural Earth draws it: the Aleutians run over the
    /// antimeridian, so its box is the whole globe at its latitudes.
    @Test("Nearby is measured to an area's outline, across the antimeridian, not to its box")
    func nearbyByOutline() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            var alaska = Self.region("US-AK", "Alaska")
            alaska.bounds = OfflineCountryManifest.Bounds(west: -180, south: 51, east: 180, north: 71.5)
            alaska.outline = OfflineCountryFixture.outline(
                of: OfflineCountryManifest.Bounds(west: -170, south: 54, east: -141, north: 71.5)
            ) + OfflineCountryFixture.outline(
                of: OfflineCountryManifest.Bounds(west: 172, south: 51, east: 180, north: 53)
            )
            let harness = await OfflineCountryHarness.make(in: directory, offering: [alaska])
            let berlin = CLLocationCoordinate2D(latitude: 52.5, longitude: 13.4)
            // A degree and a half east of the westernmost Aleutians' edge,
            // over the antimeridian: about 103 km at that latitude.
            let overTheLine = CLLocationCoordinate2D(latitude: 52, longitude: -178.5)

            #expect(harness.countries.nearby(berlin).isEmpty, "inside the box, half a world from the outline")
            #expect(harness.countries.nearby(overTheLine) == [alaska])
            #expect(alaska.kilometers(from: overTheLine).isApproximatelyEqual(to: 103, absoluteTolerance: 2))
            #expect(alaska.kilometers(from: CLLocationCoordinate2D(latitude: 61.2, longitude: -149.9)) == 0)
        }
    }

    @Test("a region is named in the app's language, in English where it has no name in that")
    func regionNames() {
        #expect(OfflineCountries.name(of: california, language: "de") == "Kalifornien")
        #expect(OfflineCountries.name(of: colorado, language: "de") == "Colorado")
        #expect(OfflineCountries.name(of: california, language: "en") == "California")
        #expect(OfflineCountries.fullName(of: colorado, language: "en") == "Colorado, United States")
        #expect(OfflineCountries.name(of: slovenia, language: "de") == "Slowenien")
        #expect(OfflineCountries.fullName(of: slovenia, language: "en") == "Slovenia")
    }
}

// swiftlint:enable no_magic_numbers
