//
//  OfflineCountriesLaunchTests.swift
//  OpenHikesTests
//
//  What a launch makes of the countries: the list kept from the last visit
//  is there with no signal, a download that landed while the app was away is
//  installed, and the list's question — which countries it puts first — is
//  answered from the outlines. Which countries a trail crosses is
//  `OfflineRouteCoverageTests`'.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import Testing

@MainActor
@Suite("Offline countries: launch and list")
struct OfflineCountriesLaunchTests {
    private let basemap = OfflineCountryFixture.archive(
        [VectorTileAddress(z: 0, x: 0, y: 0): Data("world".utf8)],
        maximumZoom: 0
    )

    private func countries(
        _ store: OfflineCountryStore,
        server: StubCountryServer,
        downloader: StubCountryDownloader = StubCountryDownloader(),
        archives: OfflineCountryArchives = OfflineCountryArchives()
    ) -> OfflineCountries {
        OfflineCountries(
            store: store,
            server: server,
            downloader: downloader,
            archives: archives,
            freeSpace: { 1 << 40 }
        )
    }

    @Test("the list kept from the last visit is there before the server answers")
    func cachedList() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let store = OfflineCountryStore(directory: directory)
            try store.prepare()
            let country = OfflineCountryFixture.country(bytes: basemap)
            try store.cache(OfflineCountryFixture.manifest([country]))
            let countries = countries(store, server: StubCountryServer(nil))

            await countries.start()
            #expect(countries.listed == [country])

            await countries.refreshList()
            #expect(countries.listPhase == .failed)
            #expect(countries.listed == [country])
        }
    }

    @Test("a fresh list is kept for the next launch")
    func keepsTheList() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let store = OfflineCountryStore(directory: directory)
            let country = OfflineCountryFixture.country(bytes: basemap)
            let countries = countries(store, server: StubCountryServer(OfflineCountryFixture.manifest([country])))

            await countries.start()
            await countries.refreshList()

            #expect(countries.listPhase == .loaded)
            #expect(store.cachedManifest()?.readableCountries == [country])
        }
    }

    /// The system finishes a background download whether or not the app is
    /// running, and moves the file into staging under its own name.
    @Test("a download that landed while the app was away is installed at launch")
    func installsWhatLanded() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let store = OfflineCountryStore(directory: directory)
            try store.prepare()
            let country = OfflineCountryFixture.country(bytes: basemap)
            let file = try #require(country.files.first)
            try store.write(pending: [OfflineCountryStore.Pending(country: country, roles: [.basemap])])
            try basemap.write(to: store.stagedURL(for: file))
            let archives = OfflineCountryArchives()
            let countries = countries(store, server: StubCountryServer(nil), archives: archives)

            await countries.start()
            await settleDelegateHop(until: "the map has the country") { !archives.isEmpty }

            #expect(countries.isInstalled("SI"))
            #expect(store.pending().isEmpty)
        }
    }

    @Test("a download still under way at launch shows how far it has come")
    func picksUpARunningDownload() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let store = OfflineCountryStore(directory: directory)
            try store.prepare()
            let country = OfflineCountryFixture.country(bytes: basemap)
            try store.write(pending: [OfflineCountryStore.Pending(country: country, roles: [.basemap])])
            let downloader = StubCountryDownloader()
            let basemapKey = OfflineCountryDownloadKey(country: "SI", build: country.build, role: .basemap)
            downloader.stillRunning = [basemapKey: 40]
            let countries = countries(store, server: StubCountryServer(nil), downloader: downloader)

            await countries.start()

            #expect(countries.downloads["SI"]?.phase == .downloading)
            #expect(countries.downloads["SI"]?.writtenBytes == 40)
        }
    }

    /// The session lost it — the app was force-quit, which cancels background
    /// transfers — so the row offers Try Again rather than a stalled ring.
    @Test("a download the session no longer has shows as failed")
    func lostDownload() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let store = OfflineCountryStore(directory: directory)
            try store.prepare()
            let country = OfflineCountryFixture.country(bytes: basemap)
            try store.write(pending: [OfflineCountryStore.Pending(country: country, roles: [.basemap])])
            let countries = countries(store, server: StubCountryServer(nil))

            await countries.start()

            #expect(countries.downloads["SI"]?.phase == .failed(.connection))
        }
    }

    /// The installed areas are listed before the session has said what it
    /// still has, so the hiker can delete one while its update waits to be
    /// picked up. The launch read the update from the list as it began, and
    /// installed it again from staging (#1530).
    @Test("an area deleted while the launch is picking up its update stays deleted")
    func deletedDuringRecovery() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let store = OfflineCountryStore(directory: directory)
            try store.prepare()
            let old = OfflineCountryFixture.country(bytes: basemap, build: "20261001")
            let oldFile = try #require(old.files.first)
            try basemap.write(to: store.fileURL(for: oldFile))
            try store.write(installed: [OfflineCountryStore.Record(country: old, installedAt: .now)])
            let new = OfflineCountryFixture.country(bytes: basemap, build: "20261117")
            let newFile = try #require(new.files.first)
            try store.write(pending: [OfflineCountryStore.Pending(country: new, roles: [.basemap])])
            try basemap.write(to: store.stagedURL(for: newFile))
            let downloader = StubCountryDownloader()
            downloader.holdsListing = true
            let countries = countries(store, server: StubCountryServer(nil), downloader: downloader)

            let launch = Task { await countries.start() }
            await settleDelegateHop(until: "the launch waits on the session's tasks") {
                !downloader.waitingForListing.isEmpty
            }
            #expect(countries.isInstalled("SI"))
            countries.delete("SI")
            #expect(!countries.isInstalled("SI"))
            #expect(downloader.cancelled == ["SI"])
            downloader.releaseListing()
            await launch.value

            #expect(!countries.isInstalled("SI"))
            #expect(countries.downloads["SI"] == nil)
            #expect(store.installed().isEmpty)
            #expect(store.pending().isEmpty)
            #expect(!FileManager.default.fileExists(atPath: store.fileURL(for: oldFile).path))
            #expect(!FileManager.default.fileExists(atPath: store.fileURL(for: newFile).path))
            #expect(!FileManager.default.fileExists(atPath: store.stagedURL(for: newFile).path))
        }
    }

    /// The areas are listed before the session has said what it still has,
    /// so a read of the list meanwhile finds an area down without the day
    /// hikes its build gained, and no row bringing them: the transfer the
    /// launch is picking up is for them, to the same staging path.
    @Test("a read of the list while the launch picks up a download asks for none of its files again")
    func listReadDuringRecovery() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let store = OfflineCountryStore(directory: directory)
            try store.prepare()
            let mapOnly = OfflineCountryFixture.country(bytes: basemap)
            let withTrails = OfflineCountryFixture.country(bytes: basemap, trails: Data("trails".utf8))
            try basemap.write(to: store.fileURL(for: try #require(mapOnly.files.first)))
            try store.write(installed: [OfflineCountryStore.Record(country: mapOnly, installedAt: .now)])
            let pending = OfflineCountryStore.Pending(country: withTrails, roles: [.trails])
            try store.write(pending: [pending])
            let downloader = StubCountryDownloader()
            downloader.holdsListing = true
            let trailsKey = OfflineCountryDownloadKey(country: "SI", build: withTrails.build, role: .trails)
            downloader.stillRunning = [trailsKey: 3]
            let server = StubCountryServer(OfflineCountryFixture.manifest([withTrails]))
            let countries = countries(store, server: server, downloader: downloader)

            let launch = Task { await countries.start() }
            await settleDelegateHop(until: "the launch waits on the session's tasks") {
                !downloader.waitingForListing.isEmpty
            }
            await countries.refreshList()
            #expect(downloader.requests.isEmpty)
            downloader.releaseListing()
            await launch.value

            #expect(countries.downloads["SI"]?.files.map(\.role) == [.trails])
            #expect(countries.downloads["SI"]?.phase == .downloading)
            #expect(downloader.requests.isEmpty, "the transfer picked up is the only one")
            #expect(store.pending() == [pending])
        }
    }

    @Test("a country still downloaded stays listed after the server stops offering it")
    func listsWhatIsInstalled() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let store = OfflineCountryStore(directory: directory)
            try store.prepare()
            let country = OfflineCountryFixture.country(bytes: basemap)
            let file = try #require(country.files.first)
            try basemap.write(to: store.fileURL(for: file))
            try store.write(installed: [OfflineCountryStore.Record(country: country, installedAt: .now)])
            let countries = countries(store, server: StubCountryServer(OfflineCountryFixture.manifest([])))

            await countries.start()
            await countries.refreshList()

            #expect(countries.listed == [country])
        }
    }

    @Test("each country is listed once, in the first section it belongs to")
    func sections() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let store = OfflineCountryStore(directory: directory)
            try store.prepare()
            let austria = OfflineCountryFixture.northernCountry(bytes: basemap)
            let slovenia = OfflineCountryFixture.country(bytes: basemap, id: "SI")
            var spain = OfflineCountryFixture.country(bytes: basemap, id: "ES")
            spain.bounds = OfflineCountryManifest.Bounds(west: -9.3, south: 36.0, east: 3.3, north: 43.8)
            spain.outline = OfflineCountryFixture.outline(of: spain.bounds)
            let file = try #require(slovenia.files.first)
            try basemap.write(to: store.fileURL(for: file))
            try store.write(installed: [OfflineCountryStore.Record(country: slovenia, installedAt: .now)])
            let server = StubCountryServer(OfflineCountryFixture.manifest([austria, slovenia, spain]))
            let countries = countries(store, server: server)
            await countries.start()
            await countries.refreshList()

            let listing = { (near: CLLocationCoordinate2D?) in
                OfflineCountryDirectory(
                    listed: countries.listed,
                    near: near,
                    letter: OfflineCountryLetter.ofTheAppLanguage()
                )
            }
            let fromLjubljana = countries.sections(
                of: listing(CLLocationCoordinate2D(latitude: 46.05, longitude: 14.5)),
                by: .nearest
            )
            #expect(fromLjubljana == OfflineCountrySections(
                downloaded: [slovenia],
                parts: [
                    OfflineCountrySections.Part(heading: .nearby, lines: [.area(austria)]),
                    OfflineCountrySections.Part(heading: .all, lines: [.area(spain)]),
                ]
            ))
            let nowhere = countries.sections(of: listing(nil), by: .nearest)
            #expect(nowhere.downloaded == [slovenia])
            #expect(nowhere.parts.map(\.heading) == [.letter("A"), .letter("S")], "by name, with no position")
            #expect(nowhere.parts.flatMap(\.lines).map(\.id) == ["AT", "ES"])
        }
    }
}
