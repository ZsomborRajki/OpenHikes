//
//  OfflineCountriesElevationTests.swift
//  OpenHikesTests
//
//  An area's heights: the squares of the elevation archive over it, which a
//  download takes beside its map, so a line there is given its heights with
//  no signal. An area already down when its build gained them offers them
//  the next time the list is read, and brings them, and only them, at the
//  hiker's tap; and of two areas that cover a square, the newer build's
//  answers. *Elevation Data*, the switch that says whether a download takes
//  them, is `OfflineCountriesElevationSwitchTests`.
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
    nonisolated static let ljubljana = CLLocationCoordinate2D(latitude: 46.05, longitude: 14.51)
    /// A square far from any area here, in the Atlantic.
    nonisolated private static let elsewhere = ElevationSquare(row: 900, column: 1100)

    nonisolated static var square: ElevationSquare {
        guard let around = ElevationSquareGrid.posts(aroundLatitude: ljubljana.latitude, longitude: ljubljana.longitude)
        else {
            Issue.record("Ljubljana is no place on the Earth")
            return elsewhere
        }
        return ElevationSquareGrid.place(of: around.northWest).square
    }

    /// Ljubljana's square, every post at `height`.
    nonisolated static func level(_ height: Int16) -> Data {
        ElevationSquareFile(rows: 450, columns: 450, heights: Array(repeating: height, count: 450 * 450)).encoded()
    }

    private let basemap = OfflineCountryFixture.archive(
        [VectorTileAddress(z: 14, x: 8852, y: 5824): Data("z14".utf8)],
        maximumZoom: 14
    )

    /// The heights' file of an area holding `bytes` for Ljubljana's square.
    nonisolated static func elevation(_ bytes: Data) -> Data {
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

    @Test("an area down before its build listed its heights offers them at the next read of the list, for a tap")
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

            #expect(harness.downloader.requests.count == asked, "gigabytes, for some areas, and nobody asked")
            #expect(harness.countries.addition(to: "SI")?.extras == .elevation)
            harness.countries.extend("SI")
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
