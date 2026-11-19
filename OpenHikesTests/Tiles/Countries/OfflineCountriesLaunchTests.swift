//
//  OfflineCountriesLaunchTests.swift
//  OpenHikesTests
//
//  What a launch makes of the countries: the list kept from the last visit
//  is there with no signal, a download that landed while the app was away is
//  installed, and the screens' questions — which countries a trail crosses,
//  which the list puts first — are answered from the outlines.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
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

    @Test("a trail's countries are the ones it passes through, in the order it reaches them")
    func countriesAlongATrail() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let store = OfflineCountryStore(directory: directory)
            let austria = OfflineCountryFixture.northernCountry(bytes: basemap)
            let slovenia = OfflineCountryFixture.country(bytes: basemap, id: "SI")
            let server = StubCountryServer(OfflineCountryFixture.manifest([austria, slovenia]))
            let countries = countries(store, server: server)
            await countries.refreshList()

            // North out of the one outline and into the other.
            let trail = [
                CLLocationCoordinate2D(latitude: 46.48, longitude: 13.78),
                CLLocationCoordinate2D(latitude: 46.85, longitude: 13.80),
                CLLocationCoordinate2D(latitude: 47.01, longitude: 13.85),
            ]
            #expect(countries.countries(along: trail).map(\.id) == ["SI", "AT"])
            #expect(countries.countries(along: [CLLocationCoordinate2D(latitude: 40, longitude: -3)]).isEmpty)
        }
    }

    /// A saved line is thinned before it is tested, and its last point is
    /// always among those tested: a trail that only just crosses a border at
    /// its end still names the country it ends in.
    @Test("a saved line's countries include the one it ends in")
    func countriesAlongASavedLine() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let austria = OfflineCountryFixture.northernCountry(bytes: basemap)
            let slovenia = OfflineCountryFixture.country(bytes: basemap, id: "SI")
            let server = StubCountryServer(OfflineCountryFixture.manifest([austria, slovenia]))
            let countries = countries(OfflineCountryStore(directory: directory), server: server)
            await countries.refreshList()
            // A thousand points in the one, and the last a step over the line.
            var route = (0..<1000).map { RouteCoordinate(latitude: 46.0 + Double($0) * 0.0009, longitude: 14.0) }
            route.append(RouteCoordinate(latitude: 47.0, longitude: 14.0))

            #expect(countries.countries(alongRoute: route, testing: 3).map(\.id) == ["SI", "AT"])
            #expect(countries.countries(alongRoute: []).isEmpty)
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
                held: [slovenia],
                parts: [
                    OfflineCountrySections.Part(heading: .nearby, lines: [.area(austria)]),
                    OfflineCountrySections.Part(heading: .all, lines: [.area(spain)]),
                ]
            ))
            let nowhere = countries.sections(of: listing(nil), by: .nearest)
            #expect(nowhere.held == [slovenia])
            #expect(nowhere.parts.map(\.heading) == [.letter("A"), .letter("S")], "by name, with no position")
            #expect(nowhere.parts.flatMap(\.lines).map(\.id) == ["AT", "ES"])
        }
    }
}
