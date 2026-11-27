//
//  OfflineCountriesElevationTests.swift
//  OpenHikesTests
//
//  An area's heights: the squares of the elevation archive over it, which a
//  download takes beside its map while *Elevation Data* is on, so a line
//  there is given its heights with no signal. An area already down when its
//  build gained them, or when the switch went on, brings them, and only
//  them; turning the switch off deletes them and keeps the area; and of two
//  areas that cover a square, the newer build's answers.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import Testing

@MainActor
@Suite("Offline countries: heights")
struct OfflineCountriesElevationTests {
    /// A point in Ljubljana, well inside its square of heights, so the four
    /// posts around it are that square's.
    nonisolated private static let ljubljana = CLLocationCoordinate2D(latitude: 46.05, longitude: 14.51)
    /// A square far from any area here, in the Atlantic.
    nonisolated private static let elsewhere = ElevationSquare(row: 900, column: 1100)

    nonisolated private static var square: ElevationSquare {
        guard let around = ElevationSquareGrid.posts(aroundLatitude: ljubljana.latitude, longitude: ljubljana.longitude)
        else {
            Issue.record("Ljubljana is no place on the Earth")
            return elsewhere
        }
        return ElevationSquareGrid.place(of: around.northWest).square
    }

    /// Ljubljana's square, every post at `height`.
    nonisolated private static func level(_ height: Int16) -> Data {
        ElevationSquareFile(rows: 450, columns: 450, heights: Array(repeating: height, count: 450 * 450)).encoded()
    }

    private let basemap = OfflineCountryFixture.archive(
        [VectorTileAddress(z: 14, x: 8852, y: 5824): Data("z14".utf8)],
        maximumZoom: 14
    )

    /// The heights' file of an area holding `bytes` for Ljubljana's square.
    nonisolated private static func elevation(_ bytes: Data) -> Data {
        guard let tile = SquareArchive.elevation.tile(named: ElevationSquareGrid.recordName(for: square)) else {
            Issue.record("Ljubljana's square is no tile")
            return Data()
        }
        return OfflineCountryFixture.archive(
            [VectorTileAddress(z: tile.zoom, x: tile.x, y: tile.y): bytes],
            maximumZoom: tile.zoom,
            minimumZoom: tile.zoom
        )
    }

    @Test("an area's download takes its heights, and a line there is given them with no signal")
    func downloadedWithTheMap() async throws {
        let elevation = Self.elevation(Self.level(295))
        let slovenia = OfflineCountryFixture.country(bytes: basemap, elevation: elevation)
        try await OfflineCountryFixture.withDirectory { directory in
            let harness = await OfflineCountryHarness.make(in: directory, offering: [slovenia])

            harness.countries.download(slovenia)
            #expect(Set(harness.downloader.requests.map(\.key.role)) == [.basemap, .elevation])
            try harness.land([.basemap: basemap, .elevation: elevation])
            await settleDelegateHop(until: "the map has the area") { !harness.archives.isEmpty }

            let found = harness.archives.elevationSquares([Self.square, Self.elsewhere])
            #expect(found == [Self.square: Self.level(295)])
            let database = StubTrailCellDatabase()
            database.fail(with: URLError(.notConnectedToInternet))
            let library = ElevationSquareLibrary(database: database, downloads: harness.archives, directory: nil)
            #expect(try await library.heights(at: [Self.ljubljana]) == [295])
            #expect(database.requests.isEmpty)
        }
    }

    @Test("an area down before its build listed its heights brings them, and only them, at the next read of the list")
    func gainedByABuildAlreadyDown() async throws {
        let elevation = Self.elevation(Self.level(295))
        let mapOnly = OfflineCountryFixture.country(bytes: basemap)
        let withHeights = OfflineCountryFixture.country(bytes: basemap, elevation: elevation)
        try await OfflineCountryFixture.withDirectory { directory in
            let harness = await OfflineCountryHarness.make(in: directory, offering: [mapOnly])
            harness.countries.setIncludesDetail(false)
            harness.countries.download(mapOnly)
            try harness.land([.basemap: basemap])
            await settleDelegateHop(until: "the area is down") {
                harness.countries.isInstalled("SI") && harness.countries.downloads["SI"] == nil
            }
            let asked = harness.downloader.requests.count

            harness.server.serve(OfflineCountryFixture.manifest([withHeights]))
            await harness.countries.refreshList()

            #expect(harness.downloader.requests.dropFirst(asked).map(\.key.role) == [.elevation])
            #expect(harness.countries.isDrawn("SI"), "the map is drawn while they come")
            try harness.land([.elevation: elevation])
            await settleDelegateHop(until: "the area has its heights") {
                harness.countries.downloads["SI"] == nil
                    && !harness.archives.elevationSquares([Self.square]).isEmpty
            }

            #expect(harness.countries.installed["SI"]?.files.map(\.role) == [.basemap, .elevation])
            #expect(harness.store.installed().first?.country == withHeights)
            #expect(withHeights.files(withDetail: false, withElevation: true).allSatisfy(harness.fileExists))
        }
    }

    @Test("with Elevation Data off, a download takes no heights, and its area says it has none")
    func switchedOff() async throws {
        let slovenia = OfflineCountryFixture.country(bytes: basemap, elevation: Self.elevation(Self.level(295)))
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
            #expect(harness.archives.elevationSquares([Self.square]).isEmpty)
        }
    }

    /// The hiker's own order: a country down without its heights, then the
    /// switch, which brings that country's heights and nothing else of it.
    @Test("a country downloaded without heights brings them, and only them, when Elevation Data is turned on")
    func turnedOnAfterTheDownload() async throws {
        let elevation = Self.elevation(Self.level(295))
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
                    && !harness.archives.elevationSquares([Self.square]).isEmpty
            }
            #expect(harness.countries.installed["SI"]?.hasElevation == true)
            #expect(harness.store.installed().first?.hasElevation == true)
            #expect(harness.fileExists(heights))
            let database = StubTrailCellDatabase()
            database.fail(with: URLError(.notConnectedToInternet))
            let library = ElevationSquareLibrary(database: database, downloads: harness.archives, directory: nil)
            #expect(try await library.heights(at: [Self.ljubljana]) == [295])
        }
    }

    @Test("turning Elevation Data off deletes the heights and keeps the area, and turning it on brings them back")
    func switchedOffAndOn() async throws {
        let elevation = Self.elevation(Self.level(295))
        let slovenia = OfflineCountryFixture.country(bytes: basemap, elevation: elevation)
        try await OfflineCountryFixture.withDirectory { directory in
            let harness = await OfflineCountryHarness.make(in: directory, offering: [slovenia])
            harness.countries.download(slovenia)
            try harness.land([.basemap: basemap, .elevation: elevation])
            await settleDelegateHop(until: "the area has its heights") {
                !harness.archives.elevationSquares([Self.square]).isEmpty
            }
            let heights = try #require(slovenia.files.first { $0.role == .elevation })
            let asked = harness.downloader.requests.count

            harness.countries.setIncludesElevation(false)
            await settleDelegateHop(until: "the heights are off the map") {
                harness.archives.elevationSquares([Self.square]).isEmpty
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
                    && !harness.archives.elevationSquares([Self.square]).isEmpty
            }
            #expect(harness.countries.installed["SI"]?.hasElevation == true)
            #expect(harness.fileExists(heights))
        }
    }

    @Test("turning Elevation Data off stops a download of the heights alone, and keeps the area")
    func switchedOffMidDownload() async throws {
        let slovenia = OfflineCountryFixture.country(bytes: basemap, elevation: Self.elevation(Self.level(295)))
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
        let elevation = Self.elevation(Self.level(295))
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
        let elevation = Self.elevation(Self.level(295))
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
        let withHeights = OfflineCountryFixture.country(bytes: basemap, elevation: Self.elevation(Self.level(295)))
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

    @Test("of two areas that cover a square, the newer build's answers")
    func newerBuildAnswers() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let older = OfflineCountryFixture.country(bytes: basemap, build: "20261117")
            let newer = OfflineCountryFixture.northernCountry(bytes: basemap)
            func area(_ country: OfflineCountryManifest.Country, build: String, holding height: Int16) throws
                -> OfflineCountryArchives.Country {
                var listed = country
                listed.build = build
                let url = directory.appending(path: "\(country.id)-elevation-\(build).pmtiles")
                try Self.elevation(Self.level(height)).write(to: url)
                let base = directory.appending(path: "\(country.id)-\(build).pmtiles")
                try basemap.write(to: base)
                return OfflineCountryArchives.Country(
                    id: country.id,
                    bounds: country.bounds,
                    basemap: try PMTilesArchive(contentsOf: base),
                    extras: nil,
                    record: OfflineCountryStore.Record(country: listed, installedAt: .now),
                    elevation: try PMTilesArchive(contentsOf: url)
                )
            }
            let archives = OfflineCountryArchives()
            archives.replace(with: [
                try area(older, build: "20261117", holding: 100),
                try area(newer, build: "20261201", holding: 200),
            ])

            #expect(archives.elevationSquares([Self.square]) == [Self.square: Self.level(200)])
            let dayHikes = archives.trailCells(named: [TrailCellFixture.name(at: 46.05, 14.5)])
            #expect(dayHikes.isEmpty, "no area here has day hikes")
        }
    }
}
