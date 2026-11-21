//
//  OfflineCountriesListingTests.swift
//  OpenHikesTests
//
//  How *Offline Maps* lists the areas by name: a country too big for one
//  download is one line that holds all its regions, a region is named in the
//  app's language and, outside its country's line, with its country, and a
//  region chosen on the map opens its country's line. The other orders, and
//  the search, are `OfflineCountryDirectoryTests`'.
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

    private func listing(
        _ countries: OfflineCountries,
        near: CLLocationCoordinate2D? = nil
    ) -> OfflineCountryDirectory {
        OfflineCountryDirectory(listed: countries.listed, near: near, letter: OfflineCountryLetter.ofTheAppLanguage())
    }

    @Test("a split country is one line under its letter, with all its regions under it by name")
    func groups() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let harness = await OfflineCountryHarness.make(in: directory, offering: [colorado, slovenia, california])
            let sections = harness.countries.sections(of: listing(harness.countries), by: .name)

            #expect(sections.unfinished.isEmpty && sections.downloaded.isEmpty)
            #expect(sections.parts == [
                OfflineCountrySections.Part(heading: .letter("S"), lines: [.area(slovenia)]),
                OfflineCountrySections.Part(
                    heading: .letter("U"),
                    lines: [.group(id: "US", regions: [california, colorado])]
                ),
            ])
        }
    }

    /// The line under the country is the whole directory of its regions, so
    /// a region coming down is under it too, as well as in *Not Yet
    /// Downloaded*.
    @Test("a region coming down is in Not Yet Downloaded and still under its country")
    func regionHeld() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let harness = await OfflineCountryHarness.make(in: directory, offering: [colorado, california])
            harness.countries.download(colorado)
            let sections = harness.countries.sections(of: listing(harness.countries), by: .name)

            #expect(sections.unfinished == [colorado])
            #expect(sections.downloaded.isEmpty)
            #expect(sections.parts.map(\.lines) == [[.group(id: "US", regions: [california, colorado])]])
            let heldTarget = sections.scrollTarget(for: "US-CO")
            #expect(heldTarget.rowID == "US-CO")
            #expect(heldTarget.opening == nil)
            let groupTarget = sections.scrollTarget(for: "US-CA")
            #expect(groupTarget.rowID == OfflineCountrySections.groupRowID("US-CA"))
            #expect(groupTarget.opening == "US")
        }
    }

    /// A store in `directory` holding Austria, and the newer build of it the
    /// server has.
    private static func storeHoldingAustria(
        in directory: URL
    ) throws -> (store: OfflineCountryStore, update: OfflineCountryManifest.Country) {
        let store = OfflineCountryStore(directory: directory)
        try store.prepare()
        let basemap = OfflineCountryFixture.archive(
            [VectorTileAddress(z: 0, x: 0, y: 0): Data("world".utf8)],
            maximumZoom: 0
        )
        let austria = OfflineCountryFixture.northernCountry(bytes: basemap)
        var update = OfflineCountryFixture.country(bytes: basemap, id: "AT", build: "20261201")
        update.bounds = austria.bounds
        update.outline = austria.outline
        let file = try #require(austria.files.first)
        try basemap.write(to: store.fileURL(for: file))
        try store.write(installed: [OfflineCountryStore.Record(country: austria, installedAt: .now)])
        return (store, update)
    }

    /// Only what is downloaded draws with no signal, so *Downloaded* holds
    /// nothing else, whatever a download is doing, in any order (#1533).
    @Test("a download waiting for Wi-Fi or refused for room is not yet downloaded, and an area updating still is")
    func notYetDownloaded() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let (store, update) = try Self.storeHoldingAustria(in: directory)
            var decision = TileNetworkDecision.allowed
            var freeBytes: Int64 = 1 << 40
            let countries = OfflineCountries(
                store: store,
                server: StubCountryServer(OfflineCountryFixture.manifest([update, slovenia, colorado, california])),
                downloader: StubCountryDownloader(),
                archives: OfflineCountryArchives(),
                networkDecision: { decision },
                freeSpace: { freeBytes }
            )
            await countries.start()
            await countries.refreshList()

            countries.download(update)
            decision = .denied("cellular-speculative")
            countries.download(slovenia)
            (decision, freeBytes) = (.allowed, 0)
            countries.download(colorado)
            #expect(countries.downloads["AT"]?.phase == .downloading)
            #expect(countries.downloads["SI"]?.phase == .waitingForWiFi)
            #expect(countries.downloads["US-CO"]?.phase == .failed(.space))

            let ljubljana = CLLocationCoordinate2D(latitude: 46.05, longitude: 14.5)
            for sort in [OfflineCountrySort.nearest, .name, .largest] {
                let sections = countries.sections(of: listing(countries, near: ljubljana), by: sort)
                #expect(sections.downloaded.map(\.id) == ["AT"], "\(sort)")
                #expect(Set(sections.unfinished.map(\.id)) == ["SI", "US-CO"], "\(sort)")
                let below = Set(sections.parts.flatMap(\.lines).map(\.id))
                #expect(below.isDisjoint(with: ["AT", "SI", "US-CO"]), "\(sort)")
                for id in ["AT", "SI", "US-CO"] {
                    #expect(sections.reveal(id, expanded: []) == .scroll(to: id), "\(sort) \(id)")
                }
            }
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
            let headings = { (near: CLLocationCoordinate2D) in
                harness.countries.sections(of: listing(harness.countries, near: near), by: .nearest)
                    .parts.map(\.heading)
            }

            #expect(headings(berlin) == [.all], "inside the box, half a world from the outline")
            #expect(headings(overTheLine) == [.nearby])
            #expect(alaska.kilometers(from: overTheLine).isApproximatelyEqual(to: 103, absoluteTolerance: 2))
            #expect(alaska.kilometers(from: CLLocationCoordinate2D(latitude: 61.2, longitude: -149.9)) == 0)
        }
    }

    @Test("only the map drawn from the tiles the areas are cut from draws them")
    func drawnOnTheOpenHikesMap() {
        #expect(OfflineCountries.areDrawn(on: .openStreetMap))
        for provider in TileProvider.all where provider.id != TileProvider.openStreetMap.id {
            #expect(!OfflineCountries.areDrawn(on: provider), "\(provider.id)")
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
