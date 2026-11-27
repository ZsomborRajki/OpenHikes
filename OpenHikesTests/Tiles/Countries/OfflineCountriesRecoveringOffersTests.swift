//
//  OfflineCountriesRecoveringOffersTests.swift
//  OpenHikesTests
//
//  A downloaded area's offers while a relaunch is still picking up what was
//  coming down. The areas are listed before the background session has said
//  what it is bringing, and for that moment an area has no row for a
//  download that is running. Offered then, *Add* started a second transfer
//  of the same file, and *Remove* deleted from the build that is down what
//  the update picked up a moment later put back. So an area the list of
//  downloads under way names offers nothing, and starts nothing, until the
//  launch has reached it; every other area offers as it always does.
//
//  Driven through the stub session held at its listing, as the launch's own
//  suites are (`OfflineCountriesLaunchTests`).
//

import Foundation
@testable import OpenHikes
import Testing

@MainActor
@Suite("Offline countries: offers while the launch picks up downloads")
struct OfflineCountriesRecoveringOffersTests {
    private typealias Role = OfflineCountryManifest.Role

    private let basemap = OfflineCountryFixture.archive(
        [VectorTileAddress(z: 14, x: 8852, y: 5824): Data("z14".utf8)],
        maximumZoom: 14
    )
    private let detail = OfflineCountryFixture.archive(
        [VectorTileAddress(z: 15, x: 17_704, y: 11_649): Data("z15".utf8)],
        maximumZoom: 15,
        minimumZoom: 15
    )

    private func slovenia(build: String = "20261117") -> OfflineCountryManifest.Country {
        OfflineCountryFixture.country(bytes: basemap, build: build, detail: detail)
    }

    /// A launch held where it asks the session what is still coming down.
    private struct HeldLaunch {
        let countries: OfflineCountries
        let downloader: StubCountryDownloader
        let store: OfflineCountryStore
        let launch: Task<Void, Never>

        /// Lets the session answer, and the launch finish.
        @MainActor
        func release() async {
            downloader.releaseListing()
            await launch.value
        }
    }

    /// Starts the model over `store` as it stands, offering `offered`, and
    /// holds its launch at the session's listing, with the list read.
    private func hold(
        _ store: OfflineCountryStore,
        offering offered: [OfflineCountryManifest.Country],
        stillRunning: [OfflineCountryDownloadKey: Int64] = [:]
    ) async -> HeldLaunch {
        let downloader = StubCountryDownloader()
        downloader.holdsListing = true
        downloader.stillRunning = stillRunning
        let countries = OfflineCountries(
            store: store,
            server: StubCountryServer(OfflineCountryFixture.manifest(offered)),
            downloader: downloader,
            archives: OfflineCountryArchives(),
            freeSpace: { 1 << 40 }
        )
        let launch = Task { await countries.start() }
        await settleDelegateHop(until: "the launch waits on the session's tasks") {
            !downloader.waitingForListing.isEmpty
        }
        await countries.refreshList()
        return HeldLaunch(countries: countries, downloader: downloader, store: store, launch: launch)
    }

    /// Writes `country` as on the device with the files in `files`.
    private func install(
        _ country: OfflineCountryManifest.Country,
        holding files: [Role: Data],
        in store: OfflineCountryStore
    ) throws {
        for file in country.files {
            try files[file.role]?.write(to: store.fileURL(for: file))
        }
        try store.write(installed: [
            OfflineCountryStore.Record(country: country, installedAt: .now, hasDetail: files[.detail] != nil),
        ])
    }

    @Test("an area whose zoom 15 the launch has yet to pick up offers none, and a tap starts no second transfer")
    func addWaitsForTheLaunch() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let store = OfflineCountryStore(directory: directory)
            try store.prepare()
            let country = slovenia()
            try install(country, holding: [.basemap: basemap], in: store)
            let pending = OfflineCountryStore.Pending(country: country, roles: [.detail])
            try store.write(pending: [pending])
            let key = OfflineCountryDownloadKey(country: "SI", build: country.build, role: .detail)
            let held = await hold(store, offering: [country], stillRunning: [key: 3])
            #expect(held.countries.isInstalled("SI"), "the area is listed before the session has answered")
            #expect(held.countries.downloads["SI"] == nil)

            #expect(held.countries.addition(to: "SI") == nil)
            held.countries.extend("SI")
            #expect(held.downloader.requests.isEmpty)
            await held.release()

            #expect(held.countries.downloads["SI"]?.files.map(\.role) == [.detail])
            #expect(held.countries.downloads["SI"]?.writtenBytes == 3, "the transfer picked up, at its own progress")
            #expect(held.downloader.requests.isEmpty, "and it is the only one")
            #expect(store.pending() == [pending])
        }
    }

    /// The update was started with *Extra Detail* on, which was turned off
    /// since. Its zoom 15 comes with it; deleting the old build's a moment
    /// before left the hiker with what they had just deleted.
    @Test("an area whose update the launch has yet to pick up offers nothing to delete, and a tap deletes nothing")
    func removeWaitsForTheLaunch() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let store = OfflineCountryStore(directory: directory)
            try store.prepare()
            let old = slovenia(build: "20261001")
            let new = slovenia()
            try install(old, holding: [.basemap: basemap, .detail: detail], in: store)
            try store.write(pending: [OfflineCountryStore.Pending(country: new, roles: [.basemap, .detail])])
            for (file, bytes) in zip(new.files, [basemap, detail]) {
                try bytes.write(to: store.stagedURL(for: file))
            }
            let oldDetail = try #require(old.files.first { $0.role == .detail })
            let held = await hold(store, offering: [new])
            held.countries.setIncludesDetail(false)

            #expect(held.countries.removal(from: "SI") == nil)
            held.countries.trim("SI")
            #expect(held.countries.installed["SI"]?.hasDetail == true)
            #expect(FileManager.default.fileExists(atPath: store.fileURL(for: oldDetail).path))
            await held.release()

            #expect(held.countries.installed["SI"]?.country == new, "the update landed as it was started")
            #expect(held.countries.installed["SI"]?.hasDetail == true)
            #expect(held.countries.removal(from: "SI")?.extras == .detail, "and its zoom 15 is then offered to delete")
        }
    }

    @Test("an area the launch has nothing to pick up for offers as ever while another's download is picked up")
    func otherAreasOfferMeanwhile() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let store = OfflineCountryStore(directory: directory)
            try store.prepare()
            let country = slovenia()
            let austria = OfflineCountryFixture.northernCountry(bytes: basemap)
            try install(country, holding: [.basemap: basemap], in: store)
            try store.write(pending: [OfflineCountryStore.Pending(country: austria, roles: [.basemap])])
            let held = await hold(store, offering: [country, austria])

            #expect(held.countries.addition(to: "SI")?.extras == .detail)
            held.countries.extend("SI")
            #expect(held.downloader.requests.map(\.key.country) == ["SI"])
            held.countries.download(austria)
            #expect(held.downloader.requests.map(\.key.country) == ["SI"], "nothing starts for the area it may pick up")
            await held.release()

            #expect(held.countries.downloads["SI"]?.files.map(\.role) == [.detail])
            #expect(held.countries.downloads["AT"]?.phase == .failed(.connection), "picked up, with nothing running")
        }
    }

    @Test("once the launch has picked its downloads up, an area that was held offers again")
    func offersAgainAfterTheLaunch() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let store = OfflineCountryStore(directory: directory)
            try store.prepare()
            let country = slovenia()
            try install(country, holding: [.basemap: basemap], in: store)
            // Listed as under way, and already in: the launch takes it off.
            try store.write(pending: [OfflineCountryStore.Pending(country: country, roles: [.basemap])])
            let held = await hold(store, offering: [country])
            #expect(held.countries.addition(to: "SI") == nil)
            await held.release()

            #expect(held.countries.downloads["SI"] == nil)
            #expect(held.countries.addition(to: "SI")?.extras == .detail)
            held.countries.extend("SI")
            #expect(held.downloader.requests.map(\.key.role) == [.detail])
        }
    }
}
