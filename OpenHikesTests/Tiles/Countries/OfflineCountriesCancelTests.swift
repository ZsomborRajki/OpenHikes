//
//  OfflineCountriesCancelTests.swift
//  OpenHikesTests
//
//  A cancelled download and the list of downloads under way agree, across a
//  launch. Taken off the list, a download is stopped and its staged files go,
//  and the next launch brings nothing back. A list that refuses the write
//  stops nothing: the row stays, its staged files stay its own, and the
//  next launch picks it up where it was (#1596). Deleting an area with an
//  update coming down cancels the update first, on the same terms.
//
//  The list is refused by marking `pending.json` immutable: still read, and
//  never replaced, as on a volume that will not take the write.
//

import Foundation
@testable import OpenHikes
import Testing

@MainActor
@Suite("Offline countries: cancelling")
struct OfflineCountriesCancelTests {
    private let basemap = OfflineCountryFixture.archive(
        [VectorTileAddress(z: 0, x: 0, y: 0): Data("world".utf8)],
        maximumZoom: 0
    )
    private let extras = OfflineCountryFixture.archive(
        [VectorTileAddress(z: 0, x: 0, y: 0): Data("extras".utf8)],
        maximumZoom: 0
    )

    /// Refuses or allows writes to the list of downloads under way.
    private static func lockTheList(_ isLocked: Bool, in directory: URL) throws {
        try FileManager.default.setAttributes(
            [.immutable: isLocked],
            ofItemAtPath: directory.appending(path: "pending.json").path
        )
    }

    /// A download of both files, the basemap staged and the extras still out.
    private func halfDown(
        in directory: URL
    ) async throws -> (harness: OfflineCountryHarness, country: OfflineCountryManifest.Country) {
        let country = OfflineCountryFixture.country(bytes: basemap, extras: extras)
        let harness = await OfflineCountryHarness.make(in: directory, offering: [country])
        harness.countries.download(country)
        try harness.downloader.land(.basemap, as: basemap)
        try #require(harness.countries.downloads["SI"]?.staged[.basemap] != nil)
        return (harness, country)
    }

    private func stagedBasemap(
        of country: OfflineCountryManifest.Country,
        in store: OfflineCountryStore
    ) throws -> URL {
        store.stagedURL(for: try #require(country.files.first { $0.role == .basemap }))
    }

    @Test("a cancelled download stays cancelled across a launch, and its staged files go")
    func cancelledStaysCancelled() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let (harness, country) = try await halfDown(in: directory)
            let staged = try stagedBasemap(of: country, in: harness.store)

            #expect(harness.countries.cancel("SI"))

            #expect(harness.countries.downloads["SI"] == nil)
            #expect(harness.downloader.cancelled == ["SI"])
            #expect(harness.store.pending().isEmpty)
            #expect(!FileManager.default.fileExists(atPath: staged.path))
            let next = await OfflineCountryHarness.make(in: directory, offering: [country])
            #expect(next.countries.downloads["SI"] == nil)
        }
    }

    @Test("a cancellation the list refuses stops nothing, and the next launch picks the download up as it was")
    func refusedCancellation() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let (harness, country) = try await halfDown(in: directory)
            let staged = try stagedBasemap(of: country, in: harness.store)
            try Self.lockTheList(true, in: directory)
            defer { try? Self.lockTheList(false, in: directory) }

            #expect(!harness.countries.cancel("SI"))

            #expect(harness.countries.downloads["SI"] != nil, "the row stays, for Cancel to be tried again")
            #expect(harness.downloader.cancelled.isEmpty, "the transfer still out runs on")
            #expect(FileManager.default.fileExists(atPath: staged.path))
            #expect(harness.store.pending().map(\.country) == [country])

            try Self.lockTheList(false, in: directory)
            let next = await OfflineCountryHarness.make(in: directory, offering: [country])
            let picked = try #require(next.countries.downloads["SI"])
            #expect(picked.staged[.basemap] != nil, "the staged basemap is still the download's")

            await next.countries.retry("SI")
            #expect(next.downloader.requests.map(\.key.role) == [.extras], "only what was not down is asked for")
            #expect(next.countries.cancel("SI"))
            let third = await OfflineCountryHarness.make(in: directory, offering: [country])
            #expect(third.countries.downloads["SI"] == nil)
        }
    }

    /// Deleting an area cancels its update first: landing on the next launch,
    /// the update would put back an area with none of its other files.
    @Test("deleting an area whose update the list will not drop keeps both, and deletes both once it will")
    func deletingWithAnUpdate() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let old = OfflineCountryFixture.country(bytes: basemap, build: "20261001")
            let new = OfflineCountryFixture.country(bytes: basemap, build: "20261117")
            let harness = await OfflineCountryHarness.make(in: directory, offering: [new])
            harness.countries.download(old)
            try harness.downloader.land(.basemap, as: basemap)
            await settleDelegateHop(until: "the old build is installed") { harness.countries.isInstalled("SI") }
            harness.countries.download(new)
            try #require(harness.store.pending().map(\.country) == [new])
            try Self.lockTheList(true, in: directory)
            defer { try? Self.lockTheList(false, in: directory) }

            harness.countries.delete("SI")

            #expect(harness.countries.isInstalled("SI"), "the area stays while its update cannot be stopped")
            #expect(harness.countries.downloads["SI"] != nil)
            #expect(harness.store.installed().map(\.country) == [old])

            try Self.lockTheList(false, in: directory)
            harness.countries.delete("SI")

            #expect(!harness.countries.isInstalled("SI"))
            #expect(harness.countries.downloads["SI"] == nil)
            #expect(harness.store.pending().isEmpty)
            let next = await OfflineCountryHarness.make(in: directory, offering: [new])
            #expect(!next.countries.isInstalled("SI"))
            #expect(next.countries.downloads["SI"] == nil)
        }
    }
}
