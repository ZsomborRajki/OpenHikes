//
//  OfflineCountriesRecoveryTests.swift
//  OpenHikesTests
//
//  What survives when a download goes wrong part of the way: a file that
//  landed while the app was away outlives the launch sweep, an update whose
//  index could not be written leaves the old build drawn, and trying again
//  after one file failed asks for that file alone while its sibling is still
//  coming down. Each was reported on #1486 and reproduced before it was
//  fixed. And files checked and then refused by the index, or by a move
//  that failed part of the way, wait in staging for Try Again or the next
//  launch to install, rather than being asked for again or read as damaged
//  (#1528).
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

    @Test("an update whose index cannot be written keeps the old build until Try Again installs the new one")
    func indexFailureKeepsTheOldBuild() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let old = OfflineCountryFixture.country(bytes: basemap, build: "20261001")
            let harness = await OfflineCountryHarness.make(in: directory, offering: [old])
            harness.countries.download(old)
            try harness.downloader.land(.basemap, as: basemap)
            await settleDelegateHop(until: "the old build is installed") { harness.countries.isInstalled("SI") }
            let index = try Self.refuseTheIndex(in: directory)
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

            try FileManager.default.removeItem(at: index)
            await harness.countries.retry("SI")
            await settleDelegateHop(until: "the update is installed") {
                harness.countries.installed["SI"]?.country.build == "20261117"
            }
            #expect(harness.downloader.requests.count == 2)
            #expect(!harness.fileExists(try #require(old.files.first)))
            #expect(harness.fileExists(try #require(new.files.first)))
        }
    }

    @Test("files the index cannot be written to name stay staged, and Try Again installs them without asking again")
    func indexFailureKeepsTheFilesStaged() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let country = OfflineCountryFixture.country(bytes: basemap, extras: extras)
            let harness = await OfflineCountryHarness.make(in: directory, offering: [country])
            let index = try Self.refuseTheIndex(in: directory)
            harness.countries.download(country)
            try harness.land([.basemap: basemap, .extras: extras])
            await settleDelegateHop(until: "the download fails") {
                harness.countries.downloads["SI"]?.phase == .failed(.space)
            }

            for file in country.files {
                #expect(!harness.fileExists(file))
                #expect(FileManager.default.fileExists(atPath: harness.store.stagedURL(for: file).path))
            }

            try FileManager.default.removeItem(at: index)
            await harness.countries.retry("SI")
            await settleDelegateHop(until: "the area is installed") { harness.countries.isInstalled("SI") }
            #expect(harness.downloader.requests.count == 2)
            #expect(country.files.allSatisfy(harness.fileExists))
            #expect(harness.store.installed().map(\.country) == [country])
        }
    }

    @Test("files the index cannot be written to name are installed by the next launch, with nothing asked again")
    func indexFailureInstallsAtTheNextLaunch() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let country = OfflineCountryFixture.country(bytes: basemap, extras: extras)
            let harness = await OfflineCountryHarness.make(in: directory, offering: [country])
            let index = try Self.refuseTheIndex(in: directory)
            harness.countries.download(country)
            try harness.land([.basemap: basemap, .extras: extras])
            await settleDelegateHop(until: "the download fails") {
                harness.countries.downloads["SI"]?.phase == .failed(.space)
            }
            try FileManager.default.removeItem(at: index)

            let relaunched = await OfflineCountryHarness.make(in: directory, offering: [country])

            #expect(relaunched.countries.isInstalled("SI"))
            #expect(relaunched.downloader.requests.isEmpty)
            #expect(country.files.allSatisfy(relaunched.fileExists))
            #expect(relaunched.store.pending().isEmpty)
        }
    }

    @Test("an install whose second move fails puts the first file back, and Try Again installs both")
    func partialInstallPutsTheFirstFileBack() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let country = OfflineCountryFixture.country(bytes: basemap, extras: extras)
            let harness = await OfflineCountryHarness.make(in: directory, offering: [country])
            let extrasFile = try #require(country.files.first { $0.role == .extras })
            // A file under the extras' name that cannot be deleted, so the
            // move of the extras into place fails after the basemap's.
            let blocker = harness.store.fileURL(for: extrasFile)
            try Data("left over".utf8).write(to: blocker)
            try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: blocker.path)
            defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: blocker.path) }
            harness.countries.download(country)
            try harness.land([.basemap: basemap, .extras: extras])
            await settleDelegateHop(until: "the install fails") {
                harness.countries.downloads["SI"]?.phase == .failed(.space)
            }

            for file in country.files {
                #expect(FileManager.default.fileExists(atPath: harness.store.stagedURL(for: file).path))
            }
            #expect(!harness.fileExists(try #require(country.files.first { $0.role == .basemap })))

            try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: blocker.path)
            await harness.countries.retry("SI")
            await settleDelegateHop(until: "the area is installed") { harness.countries.isInstalled("SI") }
            #expect(harness.downloader.requests.count == 2)
            #expect(country.files.allSatisfy(harness.fileExists))
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

    /// Puts a directory where the store writes `index.json` atomically,
    /// which refuses the write as a full volume would. Deleting what it
    /// returns lets the index be written again.
    private static func refuseTheIndex(in directory: URL) throws -> URL {
        let index = directory.appending(path: "index.json")
        if FileManager.default.fileExists(atPath: index.path) {
            try FileManager.default.removeItem(at: index)
        }
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: false)
        return index
    }
}
