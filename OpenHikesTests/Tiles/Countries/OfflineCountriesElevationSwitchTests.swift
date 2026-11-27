//
//  OfflineCountriesElevationSwitchTests.swift
//  OpenHikesTests
//
//  *Elevation Data*, the switch under *Extra Detail* that says whether a
//  download takes an area's heights: off, it takes none. The switch changes
//  no area already down. On, one without its heights offers them, and brings
//  them, and only them, at the hiker's tap; off, one with them offers to
//  delete them, and keeps them until that tap. What every download takes
//  still comes to an area unasked, and never the heights or the zoom 15 with
//  it. And an index an installed build wrote before the switch reads on.
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

    /// A file of day hikes that opens: one that did not would have its area
    /// mended before anything is offered for it.
    private let dayHikes = OfflineCountryFixture.archive(
        [VectorTileAddress(z: 14, x: 8852, y: 5824): Data("trails".utf8)],
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

    /// The owner's own order: a country down without its heights, then the
    /// switch, which starts nothing, then the tap on the offer its row makes.
    @Test("a country downloaded without heights offers them once Elevation Data is on, and brings only them at a tap")
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
            #expect(harness.countries.addition(to: "SI") == nil)

            harness.countries.setIncludesElevation(true)

            #expect(harness.downloader.requests.count == asked, "the switch asks for nothing")
            #expect(harness.countries.downloads["SI"] == nil)
            let offer = try #require(harness.countries.addition(to: "SI"))
            #expect(offer.extras == .elevation)
            #expect(offer.byteCount == heights.byteCount)

            harness.countries.extend("SI")

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
            #expect(harness.countries.addition(to: "SI") == nil)
            let database = StubTrailCellDatabase()
            database.fail(with: URLError(.notConnectedToInternet))
            let library = ElevationSquareLibrary(database: database, downloads: harness.archives, directory: nil)
            #expect(try await library.heights(at: [Heights.ljubljana]) == [295])
        }
    }

    @Test("turning Elevation Data off deletes nothing: a tap on the offer deletes the heights, and keeps the area")
    func switchedOffThenRemoved() async throws {
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
            #expect(harness.countries.installed["SI"]?.hasElevation == true)
            #expect(harness.store.installed().first?.hasElevation == true)
            #expect(harness.fileExists(heights), "the switch deletes nothing")
            let offer = try #require(harness.countries.removal(from: "SI"))
            #expect(offer.extras == .elevation)
            #expect(offer.byteCount == heights.byteCount)

            harness.countries.trim("SI")
            await settleDelegateHop(until: "the heights are off the map") {
                harness.archives.elevationSquares([Heights.square]).isEmpty
            }
            #expect(harness.countries.installed["SI"]?.hasElevation == false)
            #expect(harness.store.installed().first?.hasElevation == false)
            #expect(!harness.fileExists(heights))
            #expect(harness.countries.isDrawn("SI"), "the area stays")
            #expect(harness.countries.removal(from: "SI") == nil)

            harness.countries.setIncludesElevation(true)
            #expect(harness.downloader.requests.count == asked, "nothing was asked for")
            #expect(harness.countries.addition(to: "SI")?.extras == .elevation, "and they are offered back")
        }
    }

    /// An update is a download, and takes what the switches say as it
    /// starts. Turned off while it runs, the switch stops nothing, and
    /// cancelling the update leaves the build that is down as it was.
    @Test("cancelling an update after Elevation Data was turned off keeps the old build's heights, on offer to delete")
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
            #expect(harness.countries.downloads["SI"] != nil, "the update runs on")
            harness.countries.cancel("SI")

            #expect(harness.countries.downloads.isEmpty)
            #expect(harness.countries.installed["SI"]?.hasElevation == true)
            #expect(harness.fileExists(oldHeights))
            #expect(harness.countries.removal(from: "SI")?.extras == .elevation, "though an update is offered too")
            #expect(harness.countries.addition(to: "SI") == nil)
            #expect(harness.countries.isDrawn("SI"))

            harness.countries.download(try #require(harness.countries.update(for: "SI")))
            #expect(harness.countries.downloads["SI"]?.files.map(\.role) == [.basemap], "the next try takes none")
        }
    }

    /// An area down with neither, both switches on, as an update to this
    /// build finds every area a build before the switches left: nothing
    /// comes at launch, and the one offer brings both.
    @Test("an area down without its heights or its zoom 15 brings neither at launch, and both at one tap")
    func bothAtOneTap() async throws {
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
            #expect(harness.downloader.requests.isEmpty, "a launch and a read of the list bring neither")
            let offer = try #require(harness.countries.addition(to: "SI"))
            #expect(offer.extras == [.detail, .elevation])
            #expect(offer.byteCount == Int64(detail.count + elevation.count))

            harness.countries.extend("SI")
            #expect(harness.downloader.requests.map(\.key.role) == [.detail, .elevation])
            try harness.land([.detail: detail, .elevation: elevation])
            await settleDelegateHop(until: "both are in") { harness.countries.downloads["SI"] == nil }

            #expect(harness.countries.installed["SI"]?.files.map(\.role) == [.basemap, .detail, .elevation])
            #expect(harness.store.installed().first?.country == withAll)
            #expect(harness.countries.addition(to: "SI") == nil)

            harness.countries.setIncludesDetail(false)
            harness.countries.setIncludesElevation(false)
            #expect(harness.countries.removal(from: "SI")?.extras == [.detail, .elevation])
            harness.countries.trim("SI")
            #expect(harness.countries.installed["SI"]?.files.map(\.role) == [.basemap])
        }
    }

    /// A build that gained its day hikes and its heights since the area came
    /// down: the day hikes are every download's, and come; the heights are
    /// the switch's, and wait for the hiker.
    @Test("an area whose build gained day hikes and heights brings the day hikes unasked, and offers the heights")
    func dayHikesUnaskedHeightsOffered() async throws {
        let trails = dayHikes
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
            #expect(harness.countries.addition(to: "SI") == nil, "the row is the download's while they come")

            try harness.land([.trails: trails])
            await settleDelegateHop(until: "the day hikes are in") { harness.countries.downloads["SI"] == nil }

            #expect(harness.countries.installed["SI"]?.files.map(\.role) == [.basemap, .trails])
            #expect(harness.downloader.requests.map(\.key.role) == [.trails], "the heights are not asked for")
            let offer = try #require(harness.countries.addition(to: "SI"))
            #expect(offer.extras == .elevation)
            #expect(offer.files.map(\.role) == [.elevation])
            harness.countries.setIncludesElevation(false)
            #expect(harness.countries.addition(to: "SI") == nil)
        }
    }

    /// The hiker stopped the day hikes as they came. The area's record
    /// takes the list's entry once anything of it lands, which names them,
    /// so what the hiker then asks for brings them with it.
    @Test("an offer brings the day hikes the build gained with it, where they are not down yet")
    func offerCarriesTheDayHikes() async throws {
        let trails = dayHikes
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
            harness.countries.cancel("SI")

            let offer = try #require(harness.countries.addition(to: "SI"))
            #expect(offer.extras == .elevation)
            #expect(offer.byteCount == Int64(trails.count + elevation.count))
            harness.countries.extend("SI")
            #expect(harness.downloader.requests.dropFirst().map(\.key.role) == [.trails, .elevation])
            try harness.land([.trails: trails, .elevation: elevation])
            await settleDelegateHop(until: "both are in") { harness.countries.downloads["SI"] == nil }

            #expect(gained.files.allSatisfy(harness.fileExists))
            #expect(harness.store.installed().first?.country == gained)
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
