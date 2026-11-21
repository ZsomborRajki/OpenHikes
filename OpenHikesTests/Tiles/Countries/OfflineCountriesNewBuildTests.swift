//
//  OfflineCountriesNewBuildTests.swift
//  OpenHikesTests
//
//  A new build of an area keeps its code (#1532). The hike screen's
//  *Offline* tile keeps the areas a line crosses from the list it last read,
//  so a refresh that brings a new build under the same codes has to reach
//  it: its work keyed to the list's revision rather than to the codes, its
//  dialog showing each area as the list has it now, and a tap downloading
//  the build the server offers now rather than one it has deleted.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import Testing

@MainActor
@Suite("Offline countries: a new build under the same code")
struct OfflineCountriesNewBuildTests {
    private let basemap = OfflineCountryFixture.archive(
        [VectorTileAddress(z: 0, x: 0, y: 0): Data("world".utf8)],
        maximumZoom: 0
    )
    /// The next build's basemap, a different size, so its charge differs.
    private let nextBasemap = OfflineCountryFixture.archive(
        [VectorTileAddress(z: 0, x: 0, y: 0): Data("the world, redrawn".utf8)],
        maximumZoom: 0
    )
    /// A trail near Ljubljana, inside the fixture's Slovenia.
    private let trail = [RouteCoordinate(latitude: 46.05, longitude: 14.5)]

    private var built: OfflineCountryManifest.Country {
        OfflineCountryFixture.country(bytes: basemap, build: "20261117")
    }

    private var rebuilt: OfflineCountryManifest.Country {
        OfflineCountryFixture.country(bytes: nextBasemap, build: "20261201")
    }

    @Test("the list's revision moves when a refresh brings a new build under the same code, and only then")
    func revisionMovesWithTheBuild() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let harness = await OfflineCountryHarness.make(in: directory, offering: [built])
            let before = harness.countries.catalogRevision

            await harness.countries.refreshList()
            #expect(harness.countries.catalogRevision == before)

            harness.server.serve(OfflineCountryFixture.manifest([rebuilt]))
            await harness.countries.refreshList()

            #expect(harness.countries.listed.map(\.id) == ["SI"])
            #expect(harness.countries.catalogRevision != before)
        }
    }

    @Test("an area landing or going moves the list's revision")
    func revisionMovesWithTheDevice() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let harness = await OfflineCountryHarness.make(in: directory, offering: [built])
            let listed = harness.countries.catalogRevision

            harness.countries.download(built)
            try harness.land([.basemap: basemap])
            await settleDelegateHop(until: "the area is installed") { harness.countries.isInstalled("SI") }
            let installed = harness.countries.catalogRevision
            #expect(installed != listed)

            harness.countries.delete("SI")
            #expect(harness.countries.catalogRevision != installed)
        }
    }

    @Test("what a line crossed before the refresh is offered as the build listed now, at its size")
    func offersTheBuildListedNow() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let harness = await OfflineCountryHarness.make(in: directory, offering: [built])
            let kept = harness.countries.coverage(alongRoute: trail)
            #expect(kept.crossed == [built])

            harness.server.serve(OfflineCountryFixture.manifest([rebuilt]))
            await harness.countries.refreshList()
            let offered = harness.countries.missing(from: kept)

            #expect(offered == [rebuilt])
            #expect(offered.map { harness.countries.byteCount(of: $0) } == [Int64(nextBasemap.count)])
        }
    }

    /// The dialog's button was drawn from the earlier list, and the server
    /// deletes the build it has moved past.
    @Test("a download asked for from before the refresh fetches the build listed now")
    func downloadsTheBuildListedNow() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let harness = await OfflineCountryHarness.make(in: directory, offering: [built])
            let shown = harness.countries.missing(from: harness.countries.coverage(alongRoute: trail))
            #expect(shown == [built])

            harness.server.serve(OfflineCountryFixture.manifest([rebuilt]))
            await harness.countries.refreshList()
            for country in shown { harness.countries.downloadListed(country.id) }

            #expect(harness.countries.downloads["SI"]?.country == rebuilt)
            #expect(harness.downloader.requests.map(\.key) == [
                OfflineCountryDownloadKey(country: "SI", build: "20261201", role: .basemap),
            ])
            #expect(harness.downloader.requests.map(\.staged.lastPathComponent) == rebuilt.files.map(\.fileName))
            #expect(harness.store.pending().map(\.country) == [rebuilt])
        }
    }

    @Test("an area the list no longer holds is neither offered nor downloaded")
    func goneFromTheList() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let harness = await OfflineCountryHarness.make(in: directory, offering: [built])
            let kept = harness.countries.coverage(alongRoute: trail)

            harness.server.serve(OfflineCountryFixture.manifest([]))
            await harness.countries.refreshList()
            harness.countries.downloadListed("SI")

            #expect(harness.countries.missing(from: kept).isEmpty)
            #expect(harness.downloader.requests.isEmpty)
        }
    }

    @Test("an area downloaded since the dialog opened is not downloaded again")
    func downloadedMeanwhile() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let harness = await OfflineCountryHarness.make(in: directory, offering: [built])
            let kept = harness.countries.coverage(alongRoute: trail)
            harness.countries.download(built)
            try harness.land([.basemap: basemap])
            await settleDelegateHop(until: "the area is installed") { harness.countries.isInstalled("SI") }
            let asked = harness.downloader.requests.count

            harness.countries.downloadListed("SI")

            #expect(harness.countries.missing(from: kept).isEmpty)
            #expect(harness.downloader.requests.count == asked)
            #expect(harness.countries.downloads["SI"] == nil)
        }
    }
}
