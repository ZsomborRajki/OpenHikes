//
//  OfflineCountriesElevationSwitchTests.swift
//  OpenHikesTests
//
//  *Elevation Data*, the switch under *Extra Detail* that decides whether a
//  downloaded area brings its heights: off, a download takes none; on, every
//  area down without them brings them, and only them; off again deletes them
//  and keeps the areas, and stops a download of the heights alone, or takes
//  them off once an update that would have replaced them is cancelled. An
//  area down without its heights brings the map's files first, then the
//  heights, then zoom 15. And an index an installed build wrote before the
//  switch reads on.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import Testing

@MainActor
@Suite("Offline countries: Elevation Data")
struct OfflineCountriesElevationSwitchTests {
    /// Ljubljana's square and its file, from the heights' suite.
    private typealias Heights = OfflineCountriesElevationTests

    private let basemap = OfflineCountryFixture.archive(
        [VectorTileAddress(z: 14, x: 8852, y: 5824): Data("z14".utf8)],
        maximumZoom: 14
    )

    @Test("with Elevation Data off, a download takes no heights, and its area says it has none")
    func switchedOff() async throws {
        let slovenia = OfflineCountryFixture.country(bytes: basemap, elevation: Heights.elevation(Heights.level(295)))
        try await OfflineCountryFixture.withDirectory { directory in
            let harness = await OfflineCountryHarness.make(in: directory, offering: [slovenia])
            harness.countries.setIncludesElevation(false)

            harness.countries.download(slovenia)
            #expect(harness.downloader.requests.map(\.key.role) == [.basemap])
            let mapOnly = slovenia.byteCount(withDetail: true, withElevation: false)
            #expect(harness.countries.byteCount(of: slovenia) == mapOnly)
            try harness.land([.basemap: basemap])
            await settleDelegateHop(until: "the area is down") { harness.countries.isInstalled("SI") }

            #expect(harness.countries.installed["SI"]?.hasElevation == false)
            #expect(harness.store.installed().first?.hasElevation == false)
            #expect(harness.archives.elevationSquares([Heights.square]).isEmpty)
        }
    }

    /// The hiker's own order: a country down without its heights, then the
    /// switch, which brings that country's heights and nothing else of it.
    @Test("a country downloaded without heights brings them, and only them, when Elevation Data is turned on")
    func turnedOnAfterTheDownload() async throws {
        let elevation = Heights.elevation(Heights.level(295))
        let slovenia = OfflineCountryFixture.country(bytes: basemap, elevation: elevation)
        try await OfflineCountryFixture.withDirectory { directory in
            let harness = await OfflineCountryHarness.make(in: directory, offering: [slovenia])
            harness.countries.setIncludesElevation(false)
            harness.countries.download(slovenia)
            try harness.land([.basemap: basemap])
            await settleDelegateHop(until: "the country is down") {
                harness.countries.isInstalled("SI") && harness.countries.downloads["SI"] == nil
            }
            let asked = harness.downloader.requests.count
            let heights = try #require(slovenia.files.first { $0.role == .elevation })

            harness.countries.setIncludesElevation(true)

            #expect(harness.downloader.requests.dropFirst(asked).map(\.key.role) == [.elevation])
            #expect(harness.countries.downloads["SI"]?.byteCount == heights.byteCount)
            #expect(harness.countries.isDrawn("SI"), "the map is drawn while they come")
            try harness.land([.elevation: elevation])
            await settleDelegateHop(until: "the country has its heights") {
                harness.countries.downloads["SI"] == nil
                    && !harness.archives.elevationSquares([Heights.square]).isEmpty
            }
            #expect(harness.countries.installed["SI"]?.hasElevation == true)
            #expect(harness.store.installed().first?.hasElevation == true)
            #expect(harness.fileExists(heights))
            let database = StubTrailCellDatabase()
            database.fail(with: URLError(.notConnectedToInternet))
            let library = ElevationSquareLibrary(database: database, downloads: harness.archives, directory: nil)
            #expect(try await library.heights(at: [Heights.ljubljana]) == [295])
        }
    }

    @Test("turning Elevation Data off deletes the heights and keeps the area, and turning it on brings them back")
    func switchedOffAndOn() async throws {
        let elevation = Heights.elevation(Heights.level(295))
        let slovenia = OfflineCountryFixture.country(bytes: basemap, elevation: elevation)
        try await OfflineCountryFixture.withDirectory { directory in
            let harness = await OfflineCountryHarness.make(in: directory, offering: [slovenia])
            harness.countries.download(slovenia)
            try harness.land([.basemap: basemap, .elevation: elevation])
            await settleDelegateHop(until: "the area has its heights") {
                !harness.archives.elevationSquares([Heights.square]).isEmpty
            }
            let heights = try #require(slovenia.files.first { $0.role == .elevation })
            let asked = harness.downloader.requests.count

            harness.countries.setIncludesElevation(false)
            await settleDelegateHop(until: "the heights are off the map") {
                harness.archives.elevationSquares([Heights.square]).isEmpty
            }
            #expect(harness.countries.installed["SI"]?.hasElevation == false)
            #expect(harness.store.installed().first?.hasElevation == false)
            #expect(!harness.fileExists(heights))
            #expect(harness.countries.isDrawn("SI"), "the area stays")
            #expect(harness.downloader.requests.count == asked, "nothing was asked for")

            harness.countries.setIncludesElevation(true)
            #expect(harness.downloader.requests.dropFirst(asked).map(\.key.role) == [.elevation])
            try harness.land([.elevation: elevation])
            await settleDelegateHop(until: "the heights are back") {
                harness.countries.downloads["SI"] == nil
                    && !harness.archives.elevationSquares([Heights.square]).isEmpty
            }
            #expect(harness.countries.installed["SI"]?.hasElevation == true)
            #expect(harness.fileExists(heights))
        }
    }

    @Test("turning Elevation Data off stops a download of the heights alone, and keeps the area")
    func switchedOffMidDownload() async throws {
        let slovenia = OfflineCountryFixture.country(bytes: basemap, elevation: Heights.elevation(Heights.level(295)))
        try await OfflineCountryFixture.withDirectory { directory in
            let harness = await OfflineCountryHarness.make(in: directory, offering: [slovenia])
            harness.countries.setIncludesElevation(false)
            harness.countries.download(slovenia)
            try harness.land([.basemap: basemap])
            await settleDelegateHop(until: "the area is down") {
                harness.countries.isInstalled("SI") && harness.countries.downloads["SI"] == nil
            }
            harness.countries.setIncludesElevation(true)
            #expect(harness.countries.downloads["SI"]?.files.map(\.role) == [.elevation])

            harness.countries.setIncludesElevation(false)

            #expect(harness.countries.downloads["SI"] == nil)
            #expect(harness.downloader.cancelled == ["SI"])
            #expect(harness.store.pending().isEmpty)
            #expect(harness.countries.installed["SI"]?.hasElevation == false)
            #expect(harness.countries.isDrawn("SI"))
        }
    }

    /// An update brings the heights of its build while the switch is on.
    /// Turned off then, the switch leaves the area alone while the update
    /// runs, so cancelling the update is what takes the old build's heights
    /// off, or a hiker who turned it off for the room would not get it.
    @Test("cancelling an update after Elevation Data was turned off deletes the old build's heights, and keeps its map")
    func cancelledUpdate() async throws {
        let elevation = Heights.elevation(Heights.level(295))
        let older = OfflineCountryFixture.country(bytes: basemap, build: "20261117", elevation: elevation)
        let newer = OfflineCountryFixture.country(bytes: basemap, build: "20261201", elevation: elevation)
        try await OfflineCountryFixture.withDirectory { directory in
            let harness = await OfflineCountryHarness.make(in: directory, offering: [older])
            harness.countries.download(older)
            try harness.land([.basemap: basemap, .elevation: elevation])
            await settleDelegateHop(until: "the older build is down with its heights") {
                harness.countries.installed["SI"]?.hasElevation == true && harness.countries.downloads["SI"] == nil
            }
            let oldHeights = try #require(older.files.first { $0.role == .elevation })
            harness.server.serve(OfflineCountryFixture.manifest([newer]))
            await harness.countries.refreshList()
            harness.countries.download(try #require(harness.countries.update(for: "SI")))
            #expect(harness.countries.downloads["SI"]?.files.map(\.role) == [.basemap, .elevation])

            harness.countries.setIncludesElevation(false)
            #expect(harness.countries.downloads["SI"] != nil, "an update that brings the map too runs on")
            #expect(harness.countries.installed["SI"]?.hasElevation == true)
            harness.countries.cancel("SI")

            #expect(harness.countries.downloads["SI"] == nil)
            #expect(harness.countries.installed["SI"]?.hasElevation == false)
            #expect(harness.store.installed().first?.hasElevation == false)
            #expect(!harness.fileExists(oldHeights))
            #expect(harness.countries.isDrawn("SI"))
            #expect(harness.countries.downloads.isEmpty, "a cancel brings nothing")
        }
    }

    /// An area down with neither, both switches on, as an update to this
    /// build finds every area: the heights come on their own, then zoom 15,
    /// so turning either switch off stops only what it turned on.
    @Test("an area down without its heights or its zoom 15 brings the heights on their own, then zoom 15")
    func heightsAheadOfDetail() async throws {
        let detail = OfflineCountryFixture.archive(
            [VectorTileAddress(z: 15, x: 17_704, y: 11_649): Data("z15".utf8)],
            maximumZoom: 15,
            minimumZoom: 15
        )
        let elevation = Heights.elevation(Heights.level(295))
        let mapOnly = OfflineCountryFixture.country(bytes: basemap)
        let withAll = OfflineCountryFixture.country(bytes: basemap, detail: detail, elevation: elevation)
        try await OfflineCountryFixture.withDirectory { directory in
            let store = OfflineCountryStore(directory: directory)
            try store.prepare()
            try basemap.write(to: store.fileURL(for: try #require(mapOnly.files.first)))
            try store.write(installed: [OfflineCountryStore.Record(country: mapOnly, installedAt: .now)])
            try store.cache(OfflineCountryFixture.manifest([withAll]))
            let harness = await OfflineCountryHarness.make(in: directory, offering: [withAll])
            #expect(harness.downloader.requests.map(\.key.role) == [.elevation])

            try harness.land([.elevation: elevation])
            await settleDelegateHop(until: "the heights are in, and zoom 15 is asked for") {
                harness.countries.downloads["SI"]?.files.map(\.role) == [.detail]
            }
            #expect(harness.countries.installed["SI"]?.hasElevation == true)

            harness.countries.setIncludesDetail(false)
            #expect(harness.countries.downloads["SI"] == nil, "turning Extra Detail off stops zoom 15 alone")
            #expect(harness.countries.installed["SI"]?.files.map(\.role) == [.basemap, .elevation])
        }
    }

    /// A build that gained its day hikes and its heights since the area came
    /// down: the day hikes come on their own, so turning *Elevation Data*
    /// off while the heights come stops them and nothing else.
    @Test("an area whose build gained day hikes and heights brings the day hikes first, then the heights")
    func dayHikesAheadOfHeights() async throws {
        let trails = Data("trails".utf8)
        let elevation = Heights.elevation(Heights.level(295))
        let mapOnly = OfflineCountryFixture.country(bytes: basemap)
        let gained = OfflineCountryFixture.country(bytes: basemap, trails: trails, elevation: elevation)
        try await OfflineCountryFixture.withDirectory { directory in
            let store = OfflineCountryStore(directory: directory)
            try store.prepare()
            try basemap.write(to: store.fileURL(for: try #require(mapOnly.files.first)))
            try store.write(installed: [OfflineCountryStore.Record(country: mapOnly, installedAt: .now)])
            try store.cache(OfflineCountryFixture.manifest([gained]))
            let harness = await OfflineCountryHarness.make(in: directory, offering: [gained])
            #expect(harness.downloader.requests.map(\.key.role) == [.trails])

            try harness.land([.trails: trails])
            await settleDelegateHop(until: "the day hikes are in, and the heights are asked for") {
                harness.countries.downloads["SI"]?.files.map(\.role) == [.elevation]
            }
            harness.countries.setIncludesElevation(false)

            #expect(harness.countries.downloads["SI"] == nil)
            #expect(harness.countries.installed["SI"]?.files.map(\.role) == [.basemap, .trails])
        }
    }

    /// Every installed build wrote its index without the heights, and an
    /// index that does not read loses that build's downloads.
    @Test("an index written before Elevation Data reads on, each area with the heights its entry lists")
    func indexBeforeTheSwitch() throws {
        let plain = OfflineCountryFixture.country(bytes: basemap)
        let heights = Heights.elevation(Heights.level(295))
        let withHeights = OfflineCountryFixture.country(bytes: basemap, elevation: heights)
        for (country, expected) in [(plain, false), (withHeights, true)] {
            let written = try JSONEncoder().encode(OfflineCountryStore.Record(country: country, installedAt: .now))
            var object = try #require(try JSONSerialization.jsonObject(with: written) as? [String: Any])
            object.removeValue(forKey: "hasElevation")
            let older = try JSONSerialization.data(withJSONObject: object)

            let read = try JSONDecoder().decode(OfflineCountryStore.Record.self, from: older)

            #expect(read.hasElevation == expected)
            #expect(read.country == country)
        }
    }
}
