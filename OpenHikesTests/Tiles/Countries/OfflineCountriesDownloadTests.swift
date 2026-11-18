//
//  OfflineCountriesDownloadTests.swift
//  OpenHikesTests
//
//  A country's download from the tap to the map drawing from it: the files
//  asked for, checked against the manifest's SHA-256 before they are used,
//  and what each refusal and failure leaves on the row. The background
//  session is a stand-in that delivers what the suite says came down.
//

import Foundation
@testable import OpenHikes
import Testing

@MainActor
@Suite("Offline countries: downloads")
struct OfflineCountriesDownloadTests {
    /// A real archive, so the map's half can open it.
    private let basemap = OfflineCountryFixture.archive(
        [VectorTileAddress(z: 0, x: 0, y: 0): Data("world".utf8)],
        maximumZoom: 0
    )
    private let extras = OfflineCountryFixture.archive(
        [VectorTileAddress(z: 0, x: 0, y: 0): Data("extras".utf8)],
        maximumZoom: 0
    )

    private struct Setup {
        let countries: OfflineCountries
        let downloader: StubCountryDownloader
        let archives: OfflineCountryArchives
        let server: StubCountryServer
        let store: OfflineCountryStore
    }

    private func setUp(
        in directory: URL,
        offering offered: [OfflineCountryManifest.Country],
        decision: TileNetworkDecision = .allowed,
        freeBytes: Int64 = 1 << 40
    ) async -> Setup {
        let store = OfflineCountryStore(directory: directory)
        let server = StubCountryServer(OfflineCountryFixture.manifest(offered))
        let downloader = StubCountryDownloader()
        let archives = OfflineCountryArchives()
        let countries = OfflineCountries(
            store: store,
            server: server,
            downloader: downloader,
            archives: archives,
            networkDecision: { decision },
            freeSpace: { freeBytes }
        )
        await countries.start()
        await countries.refreshList()
        return Setup(countries: countries, downloader: downloader, archives: archives, server: server, store: store)
    }

    @Test("a country comes down, is checked, and the map draws from it")
    func installs() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let country = OfflineCountryFixture.country(bytes: basemap, extras: extras)
            let setup = await setUp(in: directory, offering: [country])

            setup.countries.download(country)
            #expect(setup.countries.downloads["SI"]?.phase == .downloading)
            #expect(Set(setup.downloader.requests.map(\.key.role)) == [.basemap, .extras])
            #expect(setup.store.pending() == [country])

            setup.downloader.progress(.basemap, 10)
            #expect(setup.countries.downloads["SI"]?.writtenBytes == 10)
            try setup.downloader.land(.basemap, as: basemap)
            try setup.downloader.land(.extras, as: extras)
            await settleDelegateHop(until: "the country is installed") { setup.countries.isInstalled("SI") }
            await settleDelegateHop(until: "the map has the country") { !setup.archives.isEmpty }

            #expect(setup.countries.downloads["SI"] == nil)
            #expect(setup.countries.installedByteCount == Int64(basemap.count + extras.count))
            #expect(setup.store.pending().isEmpty)
            #expect(setup.store.installed().map(\.country) == [country])
            let found = setup.archives.tile(for: VectorTileAddress(z: 0, x: 0, y: 0), deepest: 15, extrasFrom: 0)
            #expect(found?.basemap == Data("world".utf8))
            #expect(found?.extras == Data("extras".utf8))
        }
    }

    @Test("a file that is not the manifest's is thrown away, and the row says so")
    func damaged() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let country = OfflineCountryFixture.country(bytes: basemap)
            let setup = await setUp(in: directory, offering: [country])

            setup.countries.download(country)
            var wrong = basemap
            wrong[wrong.startIndex] ^= 0xFF
            try setup.downloader.land(.basemap, as: wrong)
            await settleDelegateHop(until: "the download is refused") {
                setup.countries.downloads["SI"]?.phase == .failed(.damaged)
            }

            #expect(!setup.countries.isInstalled("SI"))
            #expect(setup.countries.downloads["SI"]?.writtenBytes == 0)
            let staged = try #require(setup.downloader.requests.last).staged
            #expect(!FileManager.default.fileExists(atPath: staged.path))
            #expect(setup.archives.isEmpty)
        }
    }

    /// A country is gigabytes, the Wi-Fi the background session waits for
    /// costs nothing to wait for, and the policy refuses these outright.
    @Test(
        "Low Power Mode or a hot device refuses before anything is asked for",
        arguments: ["low-power-mode", "thermal"]
    )
    func conserving(reason: String) async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let country = OfflineCountryFixture.country(bytes: basemap)
            let setup = await setUp(in: directory, offering: [country], decision: .denied(reason))

            setup.countries.download(country)

            #expect(setup.countries.downloads["SI"]?.phase == .failed(.conserving))
            #expect(setup.downloader.requests.isEmpty)
        }
    }

    @Test("on cellular the download waits for Wi-Fi, and moves on when bytes arrive")
    func waitsForWiFi() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let country = OfflineCountryFixture.country(bytes: basemap)
            let setup = await setUp(in: directory, offering: [country], decision: .denied("cellular-speculative"))

            setup.countries.download(country)
            #expect(setup.countries.downloads["SI"]?.phase == .waitingForWiFi)
            #expect(setup.downloader.requests.count == 1)

            setup.downloader.progress(.basemap, 1)
            #expect(setup.countries.downloads["SI"]?.phase == .downloading)
        }
    }

    @Test("a country with no room for it and a margin is refused")
    func noRoom() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let country = OfflineCountryFixture.country(bytes: basemap)
            let setup = await setUp(
                in: directory,
                offering: [country],
                freeBytes: country.byteCount + OfflineCountries.spareBytes - 1
            )

            setup.countries.download(country)

            #expect(setup.countries.downloads["SI"]?.phase == .failed(.space))
            #expect(setup.downloader.requests.isEmpty)
        }
    }

    @Test("trying again resumes the file that stopped, and leaves the one that landed")
    func resumes() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let country = OfflineCountryFixture.country(bytes: basemap, extras: extras)
            let setup = await setUp(in: directory, offering: [country])
            let resumeData = Data("resume here".utf8)

            setup.countries.download(country)
            try setup.downloader.land(.extras, as: extras)
            setup.downloader.fail(.basemap, resumeData: resumeData)
            #expect(setup.countries.downloads["SI"]?.phase == .failed(.connection))

            setup.countries.download(country)

            let again = setup.downloader.requests.dropFirst(2)
            #expect(again.map(\.key.role) == [.basemap])
            #expect(again.first?.resumeData == resumeData)
            #expect(setup.countries.downloads["SI"]?.phase == .downloading)
        }
    }

    @Test("a download already under way is not asked for twice")
    func noSecondStart() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let country = OfflineCountryFixture.country(bytes: basemap)
            let setup = await setUp(in: directory, offering: [country])

            setup.countries.download(country)
            setup.countries.download(country)

            #expect(setup.downloader.requests.count == 1)
        }
    }

    @Test("a cancel stops the session, and keeps nothing it brought")
    func cancels() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let country = OfflineCountryFixture.country(bytes: basemap, extras: extras)
            let setup = await setUp(in: directory, offering: [country])

            setup.countries.download(country)
            try setup.downloader.land(.extras, as: extras)
            setup.countries.cancel("SI")

            #expect(setup.downloader.cancelled == ["SI"])
            #expect(setup.countries.downloads["SI"] == nil)
            #expect(setup.store.pending().isEmpty)
            for request in setup.downloader.requests {
                #expect(!FileManager.default.fileExists(atPath: request.staged.path))
            }
        }
    }

    /// The old build stays drawn until the new one is whole, so an update
    /// that fails part of the way leaves the hiker with the country they had.
    @Test("an update replaces the old build only once the new one is in")
    func updates() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let old = OfflineCountryFixture.country(bytes: basemap, build: "20261001")
            let setup = await setUp(in: directory, offering: [old])
            setup.countries.download(old)
            try setup.downloader.land(.basemap, as: basemap)
            await settleDelegateHop(until: "the old build is installed") { setup.countries.isInstalled("SI") }

            let newBytes = OfflineCountryFixture.archive(
                [VectorTileAddress(z: 0, x: 0, y: 0): Data("newer".utf8)],
                maximumZoom: 0
            )
            let new = OfflineCountryFixture.country(bytes: newBytes, build: "20261117")
            setup.server.serve(OfflineCountryFixture.manifest([new]))
            await setup.countries.refreshList()
            #expect(setup.countries.update(for: "SI") == new)

            setup.countries.download(new)
            let oldFile = try #require(old.files.first)
            #expect(FileManager.default.fileExists(atPath: setup.store.fileURL(for: oldFile).path))
            try setup.downloader.land(.basemap, as: newBytes)
            await settleDelegateHop(until: "the new build is installed") {
                setup.countries.update(for: "SI") == nil && setup.countries.downloads["SI"] == nil
            }

            #expect(setup.store.installed().map(\.country.build) == ["20261117"])
            #expect(!FileManager.default.fileExists(atPath: setup.store.fileURL(for: oldFile).path))
        }
    }

    @Test("deleting a country takes its file and its record, and the map stops drawing it")
    func deletes() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let country = OfflineCountryFixture.country(bytes: basemap)
            let setup = await setUp(in: directory, offering: [country])
            setup.countries.download(country)
            try setup.downloader.land(.basemap, as: basemap)
            await settleDelegateHop(until: "the map has the country") { !setup.archives.isEmpty }

            setup.countries.delete("SI")
            await settleDelegateHop(until: "the map has let the country go") { setup.archives.isEmpty }

            #expect(!setup.countries.isInstalled("SI"))
            #expect(setup.store.installed().isEmpty)
            let file = try #require(country.files.first)
            #expect(!FileManager.default.fileExists(atPath: setup.store.fileURL(for: file).path))
        }
    }
}
