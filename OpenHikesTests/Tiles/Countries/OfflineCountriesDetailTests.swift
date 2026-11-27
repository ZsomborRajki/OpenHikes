//
//  OfflineCountriesDetailTests.swift
//  OpenHikesTests
//
//  *Extra Detail*: an area's zoom 15, with its buildings and most of its
//  points, which a download takes only when the switch is on. Turning it on
//  brings zoom 15 to every area already down, turning it off deletes it and
//  keeps the areas, and the map draws closest in from zoom 15 where it is
//  there and from the zoom-14 tile around it where it is not.
//

import Foundation
@testable import OpenHikes
import Testing

@MainActor
@Suite("Offline countries: Extra Detail")
struct OfflineCountriesDetailTests {
    /// Ljubljana's zoom-14 tile, and one zoom-15 tile inside it.
    private static let base = VectorTileAddress(z: 14, x: 8852, y: 5824)
    private static let close = VectorTileAddress(z: 15, x: 17_704, y: 11_649)

    private let basemap = OfflineCountryFixture.archive([base: Data("z14".utf8)], maximumZoom: 14)
    private let extras = OfflineCountryFixture.archive([base: Data("extras14".utf8)], maximumZoom: 14, minimumZoom: 14)
    private let detail = OfflineCountryFixture.archive([close: Data("z15".utf8)], maximumZoom: 15, minimumZoom: 15)
    private let detailExtras = OfflineCountryFixture.archive(
        [close: Data("extras15".utf8)],
        maximumZoom: 15,
        minimumZoom: 15
    )

    private var slovenia: OfflineCountryManifest.Country {
        OfflineCountryFixture.country(bytes: basemap, extras: extras, detail: detail, detailExtras: detailExtras)
    }

    private var allFiles: [OfflineCountryManifest.Role: Data] {
        [.basemap: basemap, .extras: extras, .detail: detail, .detailExtras: detailExtras]
    }

    @Test("without Extra Detail, an area takes zoom 14, and the map draws closer in from it")
    func withoutDetail() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let harness = await OfflineCountryHarness.make(in: directory, offering: [slovenia])
            harness.countries.setIncludesDetail(false)

            harness.countries.download(slovenia)
            #expect(Set(harness.downloader.requests.map(\.key.role)) == [.basemap, .extras])
            try harness.land(allFiles.filter { !$0.key.isDetail })
            await settleDelegateHop(until: "the map has the area") { !harness.archives.isEmpty }

            let found = harness.archives.tile(for: Self.close, deepest: 15, extrasFrom: 14)
            #expect(found?.dataTile == Self.base)
            #expect(found?.basemap == Data("z14".utf8))
            #expect(found?.extras == Data("extras14".utf8))
            #expect(harness.countries.installed["SI"]?.hasDetail == false)
        }
    }

    @Test("Extra Detail is on unless the hiker turns it off, and then an area takes zoom 15 too")
    func withDetail() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let harness = await OfflineCountryHarness.make(in: directory, offering: [slovenia])
            #expect(harness.countries.includesDetail)

            harness.countries.download(slovenia)
            #expect(Set(harness.downloader.requests.map(\.key.role)) == Set(slovenia.files.map(\.role)))
            let everything = slovenia.byteCount(withDetail: true, withElevation: true)
            #expect(harness.countries.downloads["SI"]?.byteCount == everything)
            try harness.land(allFiles)
            await settleDelegateHop(until: "the map has the area") { !harness.archives.isEmpty }

            let found = harness.archives.tile(for: Self.close, deepest: 15, extrasFrom: 14)
            #expect(found?.dataTile == Self.close)
            #expect(found?.basemap == Data("z15".utf8))
            #expect(found?.extras == Data("extras15".utf8))
            // Past zoom 15, from the zoom-15 tile around it.
            let deeper = VectorTileAddress(z: 17, x: Self.close.x << 2, y: Self.close.y << 2)
            #expect(harness.archives.tile(for: deeper, deepest: 15, extrasFrom: 14)?.dataTile == Self.close)
            // Farther out, the zoom-14 file still answers.
            #expect(harness.archives.tile(for: Self.base, deepest: 15, extrasFrom: 14)?.basemap == Data("z14".utf8))
        }
    }

    @Test("turning Extra Detail on brings zoom 15, and only zoom 15, to an area already down")
    func turningOn() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let harness = await OfflineCountryHarness.make(in: directory, offering: [slovenia])
            harness.countries.setIncludesDetail(false)
            harness.countries.download(slovenia)
            try harness.land(allFiles.filter { !$0.key.isDetail })
            await settleDelegateHop(until: "the area is down") { harness.countries.isInstalled("SI") }

            harness.countries.setIncludesDetail(true)
            let added = harness.downloader.requests.dropFirst(2)
            #expect(Set(added.map(\.key.role)) == [.detail, .detailExtras])
            #expect(harness.countries.downloads["SI"]?.byteCount == Int64(detail.count + detailExtras.count))
            try harness.land(allFiles.filter(\.key.isDetail))
            await settleDelegateHop(until: "the area has its zoom 15") {
                harness.countries.installed["SI"]?.hasDetail == true && harness.countries.downloads["SI"] == nil
            }

            #expect(slovenia.files.allSatisfy(harness.fileExists))
            #expect(harness.store.installed().first?.hasDetail == true)
        }
    }

    @Test("turning Extra Detail off deletes zoom 15 and keeps the area")
    func turningOff() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let harness = await OfflineCountryHarness.make(in: directory, offering: [slovenia])
            harness.countries.download(slovenia)
            try harness.land(allFiles)
            await settleDelegateHop(until: "the map draws zoom 15") {
                harness.archives.tile(for: Self.close, deepest: 15, extrasFrom: 14)?.dataTile == Self.close
            }

            harness.countries.setIncludesDetail(false)
            await settleDelegateHop(until: "the map draws from zoom 14 again") {
                harness.archives.tile(for: Self.close, deepest: 15, extrasFrom: 14)?.dataTile == Self.base
            }

            #expect(harness.countries.installed["SI"]?.hasDetail == false)
            for file in slovenia.files {
                #expect(harness.fileExists(file) == !file.role.isDetail, "\(file.fileName)")
            }
            #expect(harness.store.installed().first?.hasDetail == false)
        }
    }

    @Test("turning Extra Detail off stops a download of zoom 15 alone, and leaves the area")
    func turningOffMidway() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let harness = await OfflineCountryHarness.make(in: directory, offering: [slovenia])
            harness.countries.setIncludesDetail(false)
            harness.countries.download(slovenia)
            try harness.land(allFiles.filter { !$0.key.isDetail })
            await settleDelegateHop(until: "the area is down") { harness.countries.isInstalled("SI") }
            harness.countries.setIncludesDetail(true)
            #expect(harness.countries.downloads["SI"] != nil)

            harness.countries.setIncludesDetail(false)

            #expect(harness.downloader.cancelled == ["SI"])
            #expect(harness.countries.downloads["SI"] == nil)
            #expect(harness.countries.isInstalled("SI"))
        }
    }

    /// The zoom 15 landing after the delete would put back a record naming
    /// the zoom-14 files just deleted: listed as downloaded, drawing nothing.
    /// With the download gone, whatever the session still delivers for it
    /// finds nothing to land in.
    @Test("deleting an area while its zoom 15 comes down stops that too")
    func deletingMidway() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            let harness = await OfflineCountryHarness.make(in: directory, offering: [slovenia])
            harness.countries.setIncludesDetail(false)
            harness.countries.download(slovenia)
            try harness.land(allFiles.filter { !$0.key.isDetail })
            await settleDelegateHop(until: "the area is down") { harness.countries.isInstalled("SI") }
            harness.countries.setIncludesDetail(true)
            #expect(harness.countries.downloads["SI"] != nil)

            harness.countries.delete("SI")

            #expect(harness.downloader.cancelled == ["SI"])
            #expect(harness.countries.downloads["SI"] == nil)
            #expect(harness.store.installed().isEmpty)
        }
    }

    @Test("Extra Detail is kept for the next launch")
    func kept() async throws {
        let suite = "offline-countries-detail-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try await OfflineCountryFixture.withDirectory { directory in
            let first = await OfflineCountryHarness.make(in: directory, offering: [slovenia], defaults: defaults)
            #expect(first.countries.includesDetail)
            first.countries.setIncludesDetail(false)

            let next = await OfflineCountryHarness.make(in: directory, offering: [slovenia], defaults: defaults)
            #expect(!next.countries.includesDetail)
        }
    }
}
