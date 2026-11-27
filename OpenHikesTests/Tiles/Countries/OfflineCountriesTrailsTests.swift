//
//  OfflineCountriesTrailsTests.swift
//  OpenHikesTests
//
//  An area's day hikes: the squares of the trails archive round it, which
//  every download takes beside its map, so the Community tab searches them
//  with no signal. An area already down when its build gained them brings
//  them, and only them, the next time the list is read; and of two areas
//  that cover a square, the newer build's answers.
//

import Foundation
@testable import OpenHikes
import Testing

@MainActor
@Suite("Offline countries: day hikes")
struct OfflineCountriesTrailsTests {
    /// The square Ljubljana is in, and one far from any area here.
    nonisolated private static let ljubljana = TrailCellFixture.name(at: 46.05, 14.5)
    nonisolated private static let elsewhere = TrailCellFixture.name(at: -22.9, -43.2)

    private let basemap = OfflineCountryFixture.archive(
        [VectorTileAddress(z: 14, x: 8852, y: 5824): Data("z14".utf8)],
        maximumZoom: 14
    )
    private let detail = OfflineCountryFixture.archive(
        [VectorTileAddress(z: 15, x: 17_704, y: 11_649): Data("z15".utf8)],
        maximumZoom: 15,
        minimumZoom: 15
    )

    /// The day hikes' file of an area holding `bytes` for Ljubljana's square.
    nonisolated private static func trails(_ bytes: Data) -> Data {
        guard let tile = SquareArchive.trails.tile(named: ljubljana) else {
            Issue.record("Ljubljana's square is no tile")
            return Data()
        }
        return OfflineCountryFixture.archive(
            [VectorTileAddress(z: tile.zoom, x: tile.x, y: tile.y): bytes],
            maximumZoom: tile.zoom,
            minimumZoom: tile.zoom
        )
    }

    private static let loop = TrailCellFile(relations: [
        TrailCellFixture.relation(
            7,
            name: "Rožnik",
            from: TrailCellFixture.point(46.05, 14.48),
            to: TrailCellFixture.point(46.06, 14.49)
        ),
    ]).encoded()

    @Test("an area's download takes its day hikes, and the archives answer for the squares they cover")
    func downloadedWithTheMap() async throws {
        let trails = Self.trails(Self.loop)
        let slovenia = OfflineCountryFixture.country(bytes: basemap, trails: trails)
        try await OfflineCountryFixture.withDirectory { directory in
            let harness = await OfflineCountryHarness.make(in: directory, offering: [slovenia])

            harness.countries.download(slovenia)
            #expect(Set(harness.downloader.requests.map(\.key.role)) == [.basemap, .trails])
            try harness.land([.basemap: basemap, .trails: trails])
            await settleDelegateHop(until: "the map has the area") { !harness.archives.isEmpty }

            let found = harness.archives.trailCells(named: [Self.ljubljana, Self.elsewhere])
            #expect(found == [Self.ljubljana: Self.loop])
        }
    }

    /// With *Extra Detail* off, and on over an area that took its zoom 15,
    /// so that neither has zoom 15 of its own to bring.
    @Test(
        "an area down before its build listed its day hikes brings them, and only them, at the next read of the list",
        arguments: [false, true]
    )
    func gainedByABuildAlreadyDown(withDetail: Bool) async throws {
        let trails = Self.trails(Self.loop)
        let mapOnly = OfflineCountryFixture.country(bytes: basemap, detail: detail)
        let withTrails = OfflineCountryFixture.country(bytes: basemap, detail: detail, trails: trails)
        try await OfflineCountryFixture.withDirectory { directory in
            let harness = await OfflineCountryHarness.make(in: directory, offering: [mapOnly])
            harness.countries.setIncludesDetail(withDetail)
            harness.countries.download(mapOnly)
            try harness.land(withDetail ? [.basemap: basemap, .detail: detail] : [.basemap: basemap])
            await settleDelegateHop(until: "the area is down") {
                harness.countries.isInstalled("SI") && harness.countries.downloads["SI"] == nil
            }
            let asked = harness.downloader.requests.count

            harness.server.serve(OfflineCountryFixture.manifest([withTrails]))
            await harness.countries.refreshList()

            #expect(harness.downloader.requests.dropFirst(asked).map(\.key.role) == [.trails])
            #expect(harness.countries.isDrawn("SI"), "the map is drawn while they come")
            try harness.land([.trails: trails])
            await settleDelegateHop(until: "the area has its day hikes") {
                harness.countries.downloads["SI"] == nil
                    && !harness.archives.trailCells(named: [Self.ljubljana]).isEmpty
            }

            let roles: [OfflineCountryManifest.Role] = withDetail ? [.basemap, .detail, .trails] : [.basemap, .trails]
            #expect(harness.countries.installed["SI"]?.files.map(\.role) == roles)
            #expect(harness.countries.installed["SI"]?.hasDetail == withDetail)
            #expect(harness.store.installed().first?.country == withTrails)
            #expect(withTrails.files(withDetail: withDetail, withElevation: true).allSatisfy(harness.fileExists))
        }
    }

    /// With *Extra Detail* on over an area down without its zoom 15. In one
    /// download with zoom 15, a zoom 15 that failed would keep the day hikes
    /// off the device once they had landed, and turning *Extra Detail* off,
    /// which stops a download of zoom 15 alone, would leave both coming.
    @Test("an area down without its zoom 15 brings its build's day hikes on their own, and then its zoom 15")
    func dayHikesAheadOfDetail() async throws {
        let trails = Self.trails(Self.loop)
        let mapOnly = OfflineCountryFixture.country(bytes: basemap, detail: detail)
        let withTrails = OfflineCountryFixture.country(bytes: basemap, detail: detail, trails: trails)
        try await OfflineCountryFixture.withDirectory { directory in
            let store = OfflineCountryStore(directory: directory)
            try store.prepare()
            try basemap.write(to: store.fileURL(for: try #require(mapOnly.files.first)))
            try store.write(installed: [OfflineCountryStore.Record(country: mapOnly, installedAt: .now)])
            try store.cache(OfflineCountryFixture.manifest([withTrails]))
            let harness = await OfflineCountryHarness.make(in: directory, offering: [withTrails])
            #expect(harness.downloader.requests.map(\.key.role) == [.trails])

            harness.downloader.fail(.trails, resumeData: nil)
            await harness.countries.retry("SI")
            #expect(harness.downloader.requests.map(\.key.role) == [.trails, .trails], "and so does a retry")
            try harness.land([.trails: trails])
            await settleDelegateHop(until: "the day hikes are in, and zoom 15 is asked for") {
                harness.countries.downloads["SI"]?.files.map(\.role) == [.detail]
                    && !harness.archives.trailCells(named: [Self.ljubljana]).isEmpty
            }
            #expect(harness.store.installed().first?.country == withTrails)

            harness.countries.setIncludesDetail(false)
            #expect(harness.countries.downloads["SI"] == nil)
            #expect(harness.store.pending().isEmpty)
            #expect(harness.countries.installed["SI"]?.files.map(\.role) == [.basemap, .trails])
        }
    }

    @Test("of two areas that cover a square, the newer build's answers")
    func newerBuildAnswers() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let older = OfflineCountryFixture.country(bytes: basemap, build: "20261117")
            let newer = OfflineCountryFixture.northernCountry(bytes: basemap)
            func area(_ country: OfflineCountryManifest.Country, build: String, holding bytes: Data) throws
                -> OfflineCountryArchives.Country {
                var listed = country
                listed.build = build
                let url = directory.appending(path: "\(country.id)-trails-\(build).pmtiles")
                try Self.trails(bytes).write(to: url)
                let base = directory.appending(path: "\(country.id)-\(build).pmtiles")
                try basemap.write(to: base)
                return OfflineCountryArchives.Country(
                    id: country.id,
                    bounds: country.bounds,
                    basemap: try PMTilesArchive(contentsOf: base),
                    extras: nil,
                    record: OfflineCountryStore.Record(country: listed, installedAt: .now),
                    trails: try PMTilesArchive(contentsOf: url)
                )
            }
            let archives = OfflineCountryArchives()
            archives.replace(with: [
                try area(older, build: "20261117", holding: Data("older".utf8)),
                try area(newer, build: "20261201", holding: Data("newer".utf8)),
            ])

            #expect(archives.trailCells(named: [Self.ljubljana]) == [Self.ljubljana: Data("newer".utf8)])
        }
    }
}
