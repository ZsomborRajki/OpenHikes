//
//  OfflineCountriesUnreadableListTests.swift
//  OpenHikesTests
//
//  What a launch does when the countries' index, or the list of downloads
//  under way, is there and cannot be read: before the device's first unlock
//  since it restarted, or written by a build this one cannot read. A list
//  that cannot be read says nothing of what the directory holds, so nothing
//  is deleted on its word (*Files outside SwiftData need an owner and a
//  sweep* in AGENTS.md: a failed fetch sweeps nothing), and the next start
//  that can read it carries on from there.
//

import Foundation
@testable import OpenHikes
import Testing

@MainActor
@Suite("Offline countries: lists that cannot be read")
struct OfflineCountriesUnreadableListTests {
    private let basemap = OfflineCountryFixture.archive(
        [VectorTileAddress(z: 0, x: 0, y: 0): Data("world".utf8)],
        maximumZoom: 0
    )
    private let unreadable = Data("not a list".utf8)

    private func countries(_ store: OfflineCountryStore, archives: OfflineCountryArchives) -> OfflineCountries {
        OfflineCountries(
            store: store,
            server: StubCountryServer(nil),
            downloader: StubCountryDownloader(),
            archives: archives,
            freeSpace: { 1 << 40 }
        )
    }

    @Test("an index that cannot be read deletes no archive, and is read by the next start that can")
    func unreadableIndex() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let store = OfflineCountryStore(directory: directory)
            try store.prepare()
            let country = OfflineCountryFixture.country(bytes: basemap)
            let file = try #require(country.files.first)
            try basemap.write(to: store.fileURL(for: file))
            let index = directory.appending(path: "index.json")
            try unreadable.write(to: index)
            let archives = OfflineCountryArchives()
            let countries = countries(store, archives: archives)

            await countries.start()
            #expect(FileManager.default.fileExists(atPath: store.fileURL(for: file).path))
            #expect(!countries.isInstalled("SI"))

            try store.write(installed: [OfflineCountryStore.Record(country: country, installedAt: .now)])
            await countries.start()
            await settleDelegateHop(until: "the map has the country") { !archives.isEmpty }
            #expect(countries.isInstalled("SI"))
            #expect(FileManager.default.fileExists(atPath: store.fileURL(for: file).path))
        }
    }

    @Test("a list of downloads that cannot be read deletes no staged file")
    func unreadablePending() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let store = OfflineCountryStore(directory: directory)
            try store.prepare()
            let country = OfflineCountryFixture.country(bytes: basemap)
            let file = try #require(country.files.first)
            try basemap.write(to: store.stagedURL(for: file))
            try unreadable.write(to: directory.appending(path: "pending.json"))
            let countries = countries(store, archives: OfflineCountryArchives())

            await countries.start()

            #expect(FileManager.default.fileExists(atPath: store.stagedURL(for: file).path))
        }
    }

    /// The other half: with no index at all, nothing owns what is there.
    @Test("with no index, an archive nothing names is still swept")
    func noIndex() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let store = OfflineCountryStore(directory: directory)
            try store.prepare()
            let country = OfflineCountryFixture.country(bytes: basemap)
            let file = try #require(country.files.first)
            try basemap.write(to: store.fileURL(for: file))
            let countries = countries(store, archives: OfflineCountryArchives())

            await countries.start()

            #expect(!FileManager.default.fileExists(atPath: store.fileURL(for: file).path))
        }
    }
}
