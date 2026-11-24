//
//  OfflineCountriesStalePendingTests.swift
//  OpenHikesTests
//
//  A launch that finds a download both installed and still on the list of
//  downloads under way: the install wrote the index and was stopped, or
//  refused, before it took the entry off the list (#1607). The area stays,
//  and the entry goes, with no failed download offering Try Again for what
//  is already drawn. An entry for a newer build, or for a file the index
//  does not hold, is still a download owed, and is picked up as one.
//

import Foundation
@testable import OpenHikes
import Testing

@MainActor
@Suite("Offline countries: a stale pending entry")
struct OfflineCountriesStalePendingTests {
    private let basemap = OfflineCountryFixture.archive(
        [VectorTileAddress(z: 0, x: 0, y: 0): Data("world".utf8)],
        maximumZoom: 0
    )
    private let extras = OfflineCountryFixture.archive(
        [VectorTileAddress(z: 0, x: 0, y: 0): Data("extras".utf8)],
        maximumZoom: 0
    )

    /// `installed` in the index with its files in place, and `waiting` on
    /// the list, as a launch finds them; nothing staged, nothing running.
    private func seed(
        _ directory: URL,
        installed country: OfflineCountryManifest.Country,
        waiting entry: OfflineCountryStore.Pending
    ) throws -> OfflineCountryStore {
        let store = OfflineCountryStore(directory: directory)
        try store.prepare()
        let record = OfflineCountryStore.Record(country: country, installedAt: Date(timeIntervalSince1970: 0))
        for file in record.files {
            try (file.role == .extras ? extras : basemap).write(to: store.fileURL(for: file))
        }
        try store.write(installed: [record])
        try store.write(pending: [entry])
        return store
    }

    @Test("an entry the index already installed is taken off the list, and is no failed download")
    func alreadyInstalled() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let country = OfflineCountryFixture.country(bytes: basemap, extras: extras)
            let store = try seed(
                directory,
                installed: country,
                waiting: OfflineCountryStore.Pending(country: country, roles: [.basemap, .extras])
            )

            let harness = await OfflineCountryHarness.make(in: directory, offering: [country])

            #expect(harness.countries.isInstalled("SI"))
            #expect(harness.countries.downloads["SI"] == nil, "nothing to try again")
            #expect(store.pending().isEmpty)
            #expect(harness.downloader.requests.isEmpty)
            #expect(store.installed().map(\.country) == [country])
        }
    }

    @Test("an entry for a newer build than the one installed is still picked up")
    func newerBuild() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let old = OfflineCountryFixture.country(bytes: basemap, build: "20261001")
            let new = OfflineCountryFixture.country(bytes: basemap, build: "20261117")
            let store = try seed(
                directory,
                installed: old,
                waiting: OfflineCountryStore.Pending(country: new, roles: [.basemap])
            )

            let harness = await OfflineCountryHarness.make(in: directory, offering: [new])

            #expect(harness.countries.isInstalled("SI"))
            #expect(harness.countries.downloads["SI"]?.phase == .failed(.connection))
            #expect(store.pending().map(\.country) == [new])
        }
    }

    @Test("an entry for a file the installed copy lacks is still picked up")
    func aFileTheIndexLacks() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let country = OfflineCountryFixture.country(bytes: basemap, extras: extras)
            let basemapOnly = OfflineCountryFixture.country(bytes: basemap)
            // Installed from a manifest that had no extras yet, under the same build.
            let store = try seed(
                directory,
                installed: basemapOnly,
                waiting: OfflineCountryStore.Pending(country: country, roles: [.extras])
            )

            let harness = await OfflineCountryHarness.make(in: directory, offering: [country])

            #expect(harness.countries.downloads["SI"]?.phase == .failed(.connection))
            #expect(store.pending().map(\.roles) == [[.extras]])
        }
    }
}
