//
//  OfflineCountriesRetryTests.swift
//  OpenHikesTests
//
//  Trying a download again, which has to leave a hiker somewhere better than
//  the failure did: with room asked only for what has not come down, with
//  what did come down kept through a refusal, and, once the tile server has
//  moved past the build that failed and deleted its files, with the build it
//  offers now rather than the same 404 at every launch, read at the tap
//  rather than when the list opened.
//

import Foundation
@testable import OpenHikes
import Testing

@MainActor
@Suite("Offline countries: trying again")
struct OfflineCountriesRetryTests {
    private let basemap = OfflineCountryFixture.archive(
        [VectorTileAddress(z: 0, x: 0, y: 0): Data("world".utf8)],
        maximumZoom: 0
    )
    private let extras = OfflineCountryFixture.archive(
        [VectorTileAddress(z: 0, x: 0, y: 0): Data("extras".utf8)],
        maximumZoom: 0
    )
    private let detail = OfflineCountryFixture.archive(
        [VectorTileAddress(z: 15, x: 0, y: 0): Data("street".utf8)],
        maximumZoom: 15,
        minimumZoom: 15
    )

    /// How much the volume has free, which a test changes between tries.
    @MainActor
    private final class Room {
        var bytes: Int64 = 1 << 40

        nonisolated deinit { /* intentionally empty */ }
    }

    private struct Setup {
        let countries: OfflineCountries
        let downloader: StubCountryDownloader
        let server: StubCountryServer
        let store: OfflineCountryStore
        let room: Room
    }

    private func setUp(in directory: URL, offering offered: [OfflineCountryManifest.Country]) async -> Setup {
        let store = OfflineCountryStore(directory: directory)
        let server = StubCountryServer(OfflineCountryFixture.manifest(offered))
        let downloader = StubCountryDownloader()
        let room = Room()
        let countries = OfflineCountries(
            store: store,
            server: server,
            downloader: downloader,
            archives: OfflineCountryArchives(),
            freeSpace: { room.bytes }
        )
        await countries.start()
        await countries.refreshList()
        return Setup(countries: countries, downloader: downloader, server: server, store: store, room: room)
    }

    // MARK: - Room

    @Test("trying again needs room only for what has not come down")
    func roomForTheRest() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let country = OfflineCountryFixture.country(bytes: basemap, extras: extras)
            let setup = await setUp(in: directory, offering: [country])
            setup.countries.download(country)
            try setup.downloader.land(.basemap, as: basemap)
            setup.downloader.fail(.extras, resumeData: nil)

            // The basemap is on the volume already, so what is free is free for the extras.
            setup.room.bytes = Int64(extras.count) + OfflineCountries.spareBytes
            setup.countries.download(country)

            #expect(setup.countries.downloads["SI"]?.phase == .downloading)
            #expect(setup.downloader.requests.dropFirst(2).map(\.key.role) == [.extras])
        }
    }

    @Test("a download refused for room keeps what has come down, and asks for the rest once there is room")
    func refusalKeepsWhatCameDown() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let country = OfflineCountryFixture.country(bytes: basemap, extras: extras)
            let setup = await setUp(in: directory, offering: [country])
            setup.countries.download(country)
            try setup.downloader.land(.basemap, as: basemap)
            setup.downloader.fail(.extras, resumeData: nil)

            setup.room.bytes = 0
            setup.countries.download(country)
            #expect(setup.countries.downloads["SI"]?.phase == .failed(.space))
            #expect(setup.downloader.requests.count == 2)

            setup.room.bytes = 1 << 40
            setup.countries.download(country)

            #expect(setup.countries.downloads["SI"]?.phase == .downloading)
            #expect(setup.downloader.requests.dropFirst(2).map(\.key.role) == [.extras])
        }
    }

    @Test("an area is refused the room another one coming down still needs")
    func sharedRoom() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let slovenia = OfflineCountryFixture.country(bytes: basemap)
            let austria = OfflineCountryFixture.northernCountry(bytes: basemap)
            let setup = await setUp(in: directory, offering: [slovenia, austria])
            setup.room.bytes = Int64(basemap.count) * 2 + OfflineCountries.spareBytes - 1

            setup.countries.download(slovenia)
            setup.countries.download(austria)

            #expect(setup.countries.downloads["SI"]?.phase == .downloading)
            #expect(setup.countries.downloads["AT"]?.phase == .failed(.space))
            #expect(setup.downloader.requests.map(\.key.country) == ["SI"])
        }
    }

    /// One file failing stops none of the others, so an area whose row
    /// says it failed can still be bringing down a gigabyte.
    @Test("an area whose download failed keeps room for the files still coming down")
    func roomForAFailedAreasTransfers() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let slovenia = OfflineCountryFixture.country(bytes: basemap, extras: extras)
            let austria = OfflineCountryFixture.northernCountry(bytes: basemap)
            let setup = await setUp(in: directory, offering: [slovenia, austria])
            setup.countries.download(slovenia)
            setup.downloader.fail(.basemap, resumeData: nil)
            #expect(setup.countries.downloads["SI"]?.hasFailed == true)

            setup.room.bytes = Int64(extras.count + basemap.count) + OfflineCountries.spareBytes - 1
            setup.countries.download(austria)
            #expect(setup.countries.downloads["AT"]?.phase == .failed(.space))

            setup.room.bytes += 1
            setup.countries.download(austria)
            #expect(setup.countries.downloads["AT"]?.phase == .downloading)
        }
    }

    /// The session hands back nothing to resume from when the partial file
    /// is gone, and the next transfer asks for every byte again.
    @Test("a file that stopped with nothing to resume from needs room for all of it again")
    func roomForAFileStartedOver() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let country = OfflineCountryFixture.country(bytes: basemap)
            let size = Int64(basemap.count)
            let setup = await setUp(in: directory, offering: [country])
            setup.countries.download(country)
            setup.downloader.progress(.basemap, size * 4 / 5)
            setup.downloader.fail(.basemap, resumeData: nil)

            setup.room.bytes = size / 2 + OfflineCountries.spareBytes
            await setup.countries.retry("SI")
            #expect(setup.countries.downloads["SI"]?.phase == .failed(.space))
            #expect(setup.downloader.requests.count == 1)

            setup.room.bytes = size + OfflineCountries.spareBytes
            await setup.countries.retry("SI")
            #expect(setup.countries.downloads["SI"]?.phase == .downloading)
            #expect(setup.downloader.requests.count == 2)
            #expect(setup.downloader.requests.last?.resumeData == nil)
        }
    }

    @Test("a file that stopped with something to resume from needs room only for the rest")
    func roomForAFileResumed() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let country = OfflineCountryFixture.country(bytes: basemap)
            let size = Int64(basemap.count)
            let setup = await setUp(in: directory, offering: [country])
            setup.countries.download(country)
            setup.downloader.progress(.basemap, size * 4 / 5)
            setup.downloader.fail(.basemap, resumeData: Data("resume here".utf8))

            setup.room.bytes = size / 2 + OfflineCountries.spareBytes
            await setup.countries.retry("SI")

            #expect(setup.countries.downloads["SI"]?.phase == .downloading)
        }
    }

    // MARK: - A build the server has moved past

    @Test("trying again once the server has moved on starts the build it offers now, and drops the old one's files")
    func movesToTheBuildOffered() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let old = OfflineCountryFixture.country(bytes: basemap, build: "20261117", extras: extras)
            let new = OfflineCountryFixture.country(bytes: basemap, build: "20261201", extras: extras)
            let setup = await setUp(in: directory, offering: [old])
            setup.countries.download(old)
            try setup.downloader.land(.extras, as: extras)
            setup.downloader.fail(.basemap, resumeData: nil)
            let stagedExtras = try #require(old.files.last.map { setup.store.stagedURL(for: $0) })
            #expect(FileManager.default.fileExists(atPath: stagedExtras.path))

            // Offline Maps read the list as it opened, and is still open.
            setup.server.serve(OfflineCountryFixture.manifest([new]))
            await setup.countries.retry("SI")

            #expect(setup.countries.downloads["SI"]?.country == new)
            #expect(setup.countries.downloads["SI"]?.phase == .downloading)
            #expect(Set(setup.downloader.requests.dropFirst(2).map(\.key)) == [
                OfflineCountryDownloadKey(country: "SI", build: "20261201", role: .basemap),
                OfflineCountryDownloadKey(country: "SI", build: "20261201", role: .extras),
            ])
            #expect(setup.store.pending().map(\.country) == [new])
            #expect(!FileManager.default.fileExists(atPath: stagedExtras.path))
        }
    }

    /// The list reads as *Offline Maps* opens, and a failed row is the
    /// first thing on it, so a tap can come before the read is back.
    @Test("trying again while the list is being read waits for that read")
    func waitsForTheReadOut() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let old = OfflineCountryFixture.country(bytes: basemap, build: "20261117")
            let new = OfflineCountryFixture.country(bytes: basemap, build: "20261201")
            let setup = await setUp(in: directory, offering: [old])
            setup.countries.download(old)
            setup.downloader.fail(.basemap, resumeData: nil)
            setup.server.serve(OfflineCountryFixture.manifest([new]))
            setup.server.hold()

            let opening = Task { await setup.countries.refreshList() }
            await settleDelegateHop(until: "the list is being read") { setup.countries.listPhase == .loading }
            let tapped = Task { await setup.countries.retry("SI") }
            setup.server.release()
            await opening.value
            await tapped.value

            #expect(setup.countries.downloads["SI"]?.country == new)
            #expect(setup.downloader.requests.dropFirst().map(\.key.build) == ["20261201"])
        }
    }

    @Test("trying again while the server still offers the build goes on from where it stopped")
    func sameBuildGoesOn() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let country = OfflineCountryFixture.country(bytes: basemap, extras: extras)
            let setup = await setUp(in: directory, offering: [country])
            let resumeData = Data("resume here".utf8)
            setup.countries.download(country)
            try setup.downloader.land(.extras, as: extras)
            setup.downloader.fail(.basemap, resumeData: resumeData)

            await setup.countries.retry("SI")

            let again = setup.downloader.requests.dropFirst(2)
            #expect(again.map(\.key.role) == [.basemap])
            #expect(again.first?.resumeData == resumeData)
        }
    }

    /// The zoom 15 of a build the server has deleted is a 404, and asked for
    /// at every launch it left a failed row on an area that was whole.
    @Test("Extra Detail asks for no zoom 15 of a build the server has moved past, and the update is offered")
    func noDetailOfAnOldBuild() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let old = OfflineCountryFixture.country(bytes: basemap, build: "20261117", detail: detail)
            let new = OfflineCountryFixture.country(bytes: basemap, build: "20261201", detail: detail)
            let setup = await setUp(in: directory, offering: [old])
            setup.countries.setIncludesDetail(false)
            setup.countries.download(old)
            try setup.downloader.land(.basemap, as: basemap)
            await settleDelegateHop(until: "the area is installed") { setup.countries.isInstalled("SI") }
            setup.server.serve(OfflineCountryFixture.manifest([new]))
            await setup.countries.refreshList()
            let asked = setup.downloader.requests.count

            setup.countries.setIncludesDetail(true)

            #expect(setup.downloader.requests.count == asked)
            #expect(setup.countries.downloads["SI"] == nil)
            #expect(setup.countries.update(for: "SI") == new)
        }
    }
}
