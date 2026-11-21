//
//  OfflineCountriesUnopenableTests.swift
//  OpenHikesTests
//
//  An area the index names whose files the map cannot open (#1534): cut
//  short, gone, or refused by the device for the moment. The area stays on
//  the device and listed, only one whose basemap opened counts as drawn, and
//  downloading it again brings the file that would not open and nothing
//  else, keeping every file that was checked.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import Testing

@MainActor
@Suite("Offline countries: an archive that will not open")
struct OfflineCountriesUnopenableTests {
    private let basemap = OfflineCountryFixture.archive(
        [VectorTileAddress(z: 0, x: 0, y: 0): Data("world".utf8)],
        maximumZoom: 0
    )
    private let extras = OfflineCountryFixture.archive(
        [VectorTileAddress(z: 0, x: 0, y: 0): Data("extras".utf8)],
        maximumZoom: 0
    )
    /// Inside the fixture's Slovenia.
    private let ljubljana = [RouteCoordinate(latitude: 46.05, longitude: 14.5)]

    /// Slovenia's basemap and extras on the device as `files` has them,
    /// named by the index, and the model started over them with the same
    /// build on offer.
    private func launch(
        in directory: URL,
        writing files: [OfflineCountryManifest.Role: Data]
    ) async throws -> (OfflineCountryHarness, OfflineCountryManifest.Country) {
        let store = OfflineCountryStore(directory: directory)
        try store.prepare()
        let country = OfflineCountryFixture.country(bytes: basemap, extras: extras)
        for file in country.files {
            try files[file.role]?.write(to: store.fileURL(for: file))
        }
        try store.write(installed: [OfflineCountryStore.Record(country: country, installedAt: .now)])
        return (await OfflineCountryHarness.make(in: directory, offering: [country]), country)
    }

    /// The issue's case: the archive registry empty, the row downloaded, and
    /// downloading the area again asking for nothing.
    @Test("an area whose basemap is cut short is drawn nowhere, and downloading it brings that file alone")
    func basemapCutShort() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let (harness, country) = try await launch(
                in: directory,
                writing: [.basemap: basemap.prefix(16), .extras: extras]
            )
            let countries = harness.countries
            let extrasFile = try #require(country.files.first { $0.role == .extras })

            #expect(harness.archives.isEmpty)
            #expect(countries.isInstalled("SI"))
            #expect(!countries.isDrawn("SI"))
            #expect(countries.needsRepair("SI"))
            let coverage = try await countries.coverage(alongRoute: ljubljana)
            #expect(countries.saving(coverage) == .unsaved)
            #expect(countries.missing(from: coverage) == [country], "the hike's tile offers it")
            #expect(countries.byteCount(of: country) == Int64(basemap.count))
            #expect(harness.downloader.requests.isEmpty, "nothing comes down unasked")

            // As the hike's tile downloads it.
            countries.downloadListed("SI")
            #expect(harness.downloader.requests.map(\.key.role) == [.basemap])
            try harness.downloader.land(.basemap, as: basemap)
            await settleDelegateHop(until: "the map has the area") { !harness.archives.isEmpty }

            #expect(countries.isDrawn("SI"))
            #expect(!countries.needsRepair("SI"))
            #expect(countries.saving(coverage) == .whole)
            #expect(countries.missing(from: coverage).isEmpty)
            #expect(harness.fileExists(extrasFile))
            let found = harness.archives.tile(for: VectorTileAddress(z: 0, x: 0, y: 0), deepest: 15, extrasFrom: 0)
            #expect(found?.basemap == Data("world".utf8))
            #expect(found?.extras == Data("extras".utf8), "the extras kept are the ones drawn")
        }
    }

    /// Before, the index left out an area with a file gone, and the launch
    /// sweep then deleted the rest of it.
    @Test("an area whose basemap has gone keeps its extras through the launch sweep, and gets the basemap back")
    func basemapGone() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let (harness, country) = try await launch(in: directory, writing: [.extras: extras])
            let extrasFile = try #require(country.files.first { $0.role == .extras })

            #expect(harness.countries.isInstalled("SI"))
            #expect(!harness.countries.isDrawn("SI"))
            #expect(harness.fileExists(extrasFile))

            harness.countries.repair("SI")
            #expect(harness.downloader.requests.map(\.key.role) == [.basemap])
        }
    }

    @Test("an area whose extras will not open is drawn and saved, and offers the extras again")
    func extrasWillNotOpen() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let (harness, country) = try await launch(
                in: directory,
                writing: [.basemap: basemap, .extras: Data("not an archive".utf8)]
            )
            let countries = harness.countries
            let basemapFile = try #require(country.files.first { $0.role == .basemap })

            #expect(!harness.archives.isEmpty)
            #expect(countries.isDrawn("SI"))
            let coverage = try await countries.coverage(alongRoute: ljubljana)
            #expect(countries.saving(coverage) == .whole)
            #expect(countries.needsRepair("SI"))

            countries.repair("SI")
            #expect(harness.downloader.requests.map(\.key.role) == [.extras])
            try harness.downloader.land(.extras, as: extras)
            await settleDelegateHop(until: "the extras open") { !countries.needsRepair("SI") }

            #expect(harness.fileExists(basemapFile))
            #expect(countries.installed["SI"]?.country == country)
        }
    }

    /// A read the device refuses, as it does before its first unlock, and
    /// then allows: the file is the one that was checked, and comes back
    /// onto the map without coming down again.
    @Test("an archive the device would not read is opened again when the app comes back, not downloaded")
    func refusedRead() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let store = OfflineCountryStore(directory: directory)
            try store.prepare()
            let country = OfflineCountryFixture.country(bytes: basemap, extras: extras)
            let basemapPath = try store.fileURL(for: #require(country.files.first { $0.role == .basemap })).path
            let (harness, _) = try await launch(in: directory, writing: [.basemap: basemap, .extras: extras])
            #expect(!harness.archives.isEmpty)

            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: basemapPath)
            // A second launch over the same directory, as the app's next one.
            let refused = await OfflineCountryHarness.make(in: directory, offering: [country])
            #expect(refused.archives.isEmpty)
            #expect(refused.countries.needsRepair("SI"))

            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: basemapPath)
            await refused.countries.start()
            await settleDelegateHop(until: "the map has the area") { !refused.archives.isEmpty }

            #expect(!refused.countries.needsRepair("SI"))
            #expect(refused.downloader.requests.isEmpty)
            #expect(FileManager.default.contents(atPath: basemapPath) == basemap)
        }
    }
}
