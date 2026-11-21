//
//  OfflineCountriesRecoveryTests.swift
//  OpenHikesTests
//
//  What survives when a download goes wrong part of the way: a file that
//  landed while the app was away outlives the launch sweep, an update whose
//  index could not be written leaves the old build drawn, trying again
//  after one file failed asks for that file alone while its sibling is still
//  coming down, and a download the list of downloads under way cannot name
//  starts no transfer, which a relaunch could not pick up. The first three
//  were reported on #1486 and the last on #1529, and each was reproduced
//  before it was fixed.
//

import Foundation
@testable import OpenHikes
import Testing

@MainActor
@Suite("Offline countries: recovery")
struct OfflineCountriesRecoveryTests {
    private let basemap = OfflineCountryFixture.archive(
        [VectorTileAddress(z: 0, x: 0, y: 0): Data("world".utf8)],
        maximumZoom: 0
    )
    private let extras = OfflineCountryFixture.archive(
        [VectorTileAddress(z: 0, x: 0, y: 0): Data("extras".utf8)],
        maximumZoom: 0
    )

    @Test("an area that landed while the app was away is installed, and still there after the launch sweep")
    func landedSurvivesTheSweep() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let store = OfflineCountryStore(directory: directory)
            try store.prepare()
            let country = OfflineCountryFixture.country(bytes: basemap)
            let file = try #require(country.files.first)
            try store.write(pending: [OfflineCountryStore.Pending(country: country, roles: [.basemap])])
            try basemap.write(to: store.stagedURL(for: file))

            let harness = await OfflineCountryHarness.make(in: directory, offering: [])

            #expect(harness.countries.isInstalled("SI"))
            #expect(harness.fileExists(file))
            #expect(store.installed().map(\.country) == [country])
        }
    }

    @Test("an update whose index cannot be written keeps the old build, and drops the new one")
    func indexFailureKeepsTheOldBuild() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let old = OfflineCountryFixture.country(bytes: basemap, build: "20261001")
            let harness = await OfflineCountryHarness.make(in: directory, offering: [old])
            harness.countries.download(old)
            try harness.downloader.land(.basemap, as: basemap)
            await settleDelegateHop(until: "the old build is installed") { harness.countries.isInstalled("SI") }
            // The store writes `index.json` atomically, which a directory under
            // that name refuses, as a full volume would.
            let index = directory.appending(path: "index.json")
            try FileManager.default.removeItem(at: index)
            try FileManager.default.createDirectory(at: index, withIntermediateDirectories: false)
            let new = OfflineCountryFixture.country(bytes: extras, build: "20261117")
            harness.server.serve(OfflineCountryFixture.manifest([new]))
            await harness.countries.refreshList()

            harness.countries.download(new)
            try harness.downloader.land(.basemap, as: extras)
            await settleDelegateHop(until: "the update fails") {
                harness.countries.downloads["SI"]?.phase == .failed(.space)
            }

            #expect(harness.countries.installed["SI"]?.country.build == "20261001")
            #expect(harness.fileExists(try #require(old.files.first)))
            #expect(!harness.fileExists(try #require(new.files.first)))
        }
    }

    @Test("trying again after one file failed asks for that file alone while the other is still coming down")
    func retryLeavesTheSibling() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let country = OfflineCountryFixture.country(bytes: basemap, extras: extras)
            let harness = await OfflineCountryHarness.make(in: directory, offering: [country])

            harness.countries.download(country)
            harness.downloader.fail(.extras, resumeData: nil)
            #expect(harness.countries.downloads["SI"]?.phase == .failed(.connection))
            harness.countries.download(country)

            #expect(harness.downloader.requests.map(\.key.role) == [.basemap, .extras, .extras])
            // The basemap's first transfer still finishes the download.
            try harness.downloader.land(.basemap, as: basemap)
            try harness.downloader.land(.extras, as: extras)
            await settleDelegateHop(until: "the area is installed") { harness.countries.isInstalled("SI") }
        }
    }

    /// A relaunch picks up only the transfers the list of downloads under
    /// way names, and sweeps the staged files of the rest.
    @Test("a download the list of downloads under way cannot name starts no transfer, and starts on Try Again")
    func unlistedDownloadStartsNothing() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let country = OfflineCountryFixture.country(bytes: basemap)
            let harness = await OfflineCountryHarness.make(in: directory, offering: [country])
            // A directory under the list's name can be neither read nor
            // written over.
            let list = directory.appending(path: "pending.json")
            try FileManager.default.createDirectory(at: list, withIntermediateDirectories: false)

            harness.countries.download(country)

            #expect(harness.downloader.requests.isEmpty)
            #expect(harness.countries.downloads["SI"]?.phase == .failed(.space))

            try FileManager.default.removeItem(at: list)
            await harness.countries.retry("SI")

            #expect(harness.downloader.requests.map(\.key.role) == [.basemap])
            #expect(harness.store.pending().map(\.country) == [country])
            try harness.downloader.land(.basemap, as: basemap)
            await settleDelegateHop(until: "the area is installed") { harness.countries.isInstalled("SI") }
        }
    }

    /// The list is written atomically, so a write refused part of the way
    /// through a try leaves the entry the try before it wrote, which still
    /// names the transfer that one has out.
    @Test("trying again while the list cannot be written keeps its entry, and starts once it can")
    func refusedWriteKeepsTheEntry() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let country = OfflineCountryFixture.country(bytes: basemap, extras: extras)
            let harness = await OfflineCountryHarness.make(in: directory, offering: [country])
            harness.countries.download(country)
            harness.downloader.fail(.extras, resumeData: nil)
            let list = directory.appending(path: "pending.json")
            let listed = try Data(contentsOf: list)

            // Readable, and nothing in it can be made, renamed or removed.
            try Self.setWritable(false, directory)
            defer { try? Self.setWritable(true, directory) }
            await harness.countries.retry("SI")

            #expect(harness.downloader.requests.map(\.key.role) == [.basemap, .extras])
            #expect(harness.countries.downloads["SI"]?.phase == .failed(.space))
            #expect(try Data(contentsOf: list) == listed)

            try Self.setWritable(true, directory)
            await harness.countries.retry("SI")

            #expect(harness.downloader.requests.map(\.key.role) == [.basemap, .extras, .extras])
            try harness.land([.basemap: basemap, .extras: extras])
            await settleDelegateHop(until: "the area is installed") { harness.countries.isInstalled("SI") }
        }
    }

    private static func setWritable(_ isWritable: Bool, _ directory: URL) throws {
        let readOnly = 0o555
        let readWrite = 0o755
        try FileManager.default.setAttributes(
            [.posixPermissions: isWritable ? readWrite : readOnly],
            ofItemAtPath: directory.path
        )
    }
}
