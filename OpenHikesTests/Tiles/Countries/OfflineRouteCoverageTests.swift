//
//  OfflineRouteCoverageTests.swift
//  OpenHikesTests
//
//  What the hike screen's *Offline* tile says of a trail: *Saved* only when
//  every walked leg of the line is inside downloaded countries from end to
//  end, and partly saved when a country it crosses is down but the line runs
//  on into one that is not, or into ground no country on offer covers. How
//  a leg is tested is `OfflineRouteLegCoverageTests`'.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import Testing

@MainActor
@Suite("Offline countries: a trail's coverage")
struct OfflineRouteCoverageTests {
    private let basemap = OfflineCountryFixture.archive(
        [VectorTileAddress(z: 0, x: 0, y: 0): Data("world".utf8)],
        maximumZoom: 0
    )

    /// From Ljubljana north over the Karawanks: inside the fixture's
    /// Slovenia, then inside its Austria.
    private let northward = [
        RouteCoordinate(latitude: 46.48, longitude: 13.78),
        RouteCoordinate(latitude: 46.85, longitude: 13.80),
        RouteCoordinate(latitude: 47.01, longitude: 13.85),
    ]

    /// `offered` on the list, and `installed` of them on the device.
    private func countries(
        in directory: URL,
        offering offered: [OfflineCountryManifest.Country],
        installed: [OfflineCountryManifest.Country]
    ) async throws -> OfflineCountries {
        let store = OfflineCountryStore(directory: directory)
        try store.prepare()
        for country in installed {
            for file in country.files { try basemap.write(to: store.fileURL(for: file)) }
        }
        try store.write(installed: installed.map { OfflineCountryStore.Record(country: $0, installedAt: .now) })
        let countries = OfflineCountries(
            store: store,
            server: StubCountryServer(OfflineCountryFixture.manifest(offered)),
            downloader: StubCountryDownloader(),
            archives: OfflineCountryArchives(),
            freeSpace: { 1 << 40 }
        )
        await countries.start()
        await countries.refreshList()
        return countries
    }

    @Test("a trail inside a downloaded country is saved")
    func wholeTrail() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let slovenia = OfflineCountryFixture.country(bytes: basemap)
            let countries = try await countries(in: directory, offering: [slovenia], installed: [slovenia])

            let coverage = try await countries.coverage(alongRoute: Array(northward.prefix(1)))

            #expect(coverage == OfflineRouteCoverage(crossed: [slovenia], leavesThem: false))
            #expect(countries.saving(coverage) == .whole)
        }
    }

    /// The review's case: Slovenia the only country there is, and the trail
    /// going on into Austria, where the map would go blank.
    @Test("a trail that runs on past every country on offer is only partly saved")
    func leavesTheCountries() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let slovenia = OfflineCountryFixture.country(bytes: basemap)
            let countries = try await countries(in: directory, offering: [slovenia], installed: [slovenia])

            let coverage = try await countries.coverage(alongRoute: northward)

            #expect(coverage == OfflineRouteCoverage(crossed: [slovenia], leavesThem: true))
            #expect(countries.saving(coverage) == .part)
        }
    }

    @Test("a trail into a country not yet downloaded is partly saved")
    func countryStillMissing() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let austria = OfflineCountryFixture.northernCountry(bytes: basemap)
            let slovenia = OfflineCountryFixture.country(bytes: basemap)
            let countries = try await countries(
                in: directory,
                offering: [austria, slovenia],
                installed: [slovenia]
            )

            let coverage = try await countries.coverage(alongRoute: northward)

            #expect(coverage.crossed.map(\.id) == ["SI", "AT"])
            #expect(!coverage.leavesThem)
            #expect(countries.saving(coverage) == .part)
        }
    }

    @Test("a trail in no country on offer crosses none, and leaves them")
    func noCountryOnOffer() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let austria = OfflineCountryFixture.northernCountry(bytes: basemap)
            let slovenia = OfflineCountryFixture.country(bytes: basemap)
            let countries = try await countries(in: directory, offering: [austria, slovenia], installed: [])

            let coverage = try await countries.coverage(alongRoute: [RouteCoordinate(latitude: 40, longitude: -3)])

            #expect(coverage == OfflineRouteCoverage(crossed: [], leavesThem: true))
            #expect(countries.saving(coverage) == .unsaved)
        }
    }

    @Test("a trail with none of its countries downloaded is not saved")
    func nothingDownloaded() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let slovenia = OfflineCountryFixture.country(bytes: basemap)
            let countries = try await countries(in: directory, offering: [slovenia], installed: [])

            #expect(try await countries.saving(countries.coverage(alongRoute: northward)) == .unsaved)
            #expect(try await countries.coverage(alongRoute: []) == OfflineRouteCoverage())
        }
    }

    /// Every leg is tested, the last among them, so a step over the edge at
    /// the very end of a long line counts.
    @Test("a trail that leaves the countries only at its last point is partly saved")
    func leavesAtTheEnd() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let slovenia = OfflineCountryFixture.country(bytes: basemap)
            let countries = try await countries(in: directory, offering: [slovenia], installed: [slovenia])
            var route = (0..<1000).map { RouteCoordinate(latitude: 46.0 + Double($0) * 0.0009, longitude: 14.0) }
            route.append(RouteCoordinate(latitude: 47.0, longitude: 14.0))

            let coverage = try await countries.coverage(alongRoute: route)

            #expect(coverage.leavesThem)
            #expect(countries.saving(coverage) == .part)
        }
    }

    /// The same: a trail that only just crosses a border on its last leg
    /// still names the country it ends in.
    @Test("a trail's countries include the one it ends in")
    func endsInTheNextCountry() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let austria = OfflineCountryFixture.northernCountry(bytes: basemap)
            let slovenia = OfflineCountryFixture.country(bytes: basemap)
            let countries = try await countries(in: directory, offering: [austria, slovenia], installed: [])
            var route = (0..<1000).map { RouteCoordinate(latitude: 46.0 + Double($0) * 0.0009, longitude: 14.0) }
            route.append(RouteCoordinate(latitude: 47.0, longitude: 14.0))

            let coverage = try await countries.coverage(alongRoute: route)

            #expect(coverage.crossed.map(\.id) == ["SI", "AT"])
            #expect(!coverage.leavesThem)
        }
    }

    /// #1531: both ends of the one walked leg are inside the downloaded
    /// country, and its middle crosses the bay of the outline, where the map
    /// goes blank. Tested at its ends alone, the line read as saved.
    @Test("a sparse leg across the bay of a downloaded country's outline is only partly saved")
    func sparseLegLeavesAConcaveCountry() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let slovenia = OfflineCountryFixture.concaveCountry(bytes: basemap)
            let countries = try await countries(in: directory, offering: [slovenia], installed: [slovenia])

            let coverage = try await countries.coverage(
                alongRoute: [OfflineCountryFixture.westernArm, OfflineCountryFixture.easternArm]
            )

            #expect(coverage == OfflineRouteCoverage(crossed: [slovenia], leavesThem: true))
            #expect(countries.saving(coverage) == .part)
        }
    }
}
