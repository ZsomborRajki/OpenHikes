//
//  AutoSaveCountryTests.swift
//  OpenHikesTests
//
//  A tile a downloaded country holds draws with no signal out of the
//  country's own files, so auto-save leaves it in the cache: kept as well, it
//  would be the same ground on disk twice, counted against the hike's cap.
//  What no country holds is kept as it always was: ground outside the
//  outline, a gap in the country's archive, where the map fell back to the
//  server, and any other map's tile of the same ground, which no country
//  draws.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import Testing

@Suite("Auto-save beside a downloaded country")
struct AutoSaveCountryTests {
    /// Zoom 14's tile over Ljubljana, inside the fixture's Slovenia, the one
    /// beside it, both in its archive, one more beside that, inside the
    /// outline but missing from the archive, and one over Madrid, outside it.
    private static let inside = VectorTileAddress(z: 14, x: 8851, y: 5825)
    private static let beside = VectorTileAddress(z: 14, x: 8852, y: 5825)
    private static let gap = VectorTileAddress(z: 14, x: 8853, y: 5825)
    private static let outside = VectorTileAddress(z: 14, x: 8023, y: 6178)
    /// How deep the OpenHikes map's source draws, as the sandbox's has it.
    private static let deepest = 15

    private let hikeID = UUID()
    private let archives = OfflineCountryArchives()
    private let sandbox: TileSandbox

    init() throws {
        let planet = try #require(URL(string: "https://vector.example.invalid/planet"))
        sandbox = TileSandbox(
            vectorSources: ["osm": VectorTileSource(archiveURL: planet, maximumZ: Self.deepest)],
            countryArchives: archives
        )
    }

    private static func key(_ tile: VectorTileAddress, provider: String = "osm") -> String {
        "\(provider)/\(tile.z)/\(tile.x)/\(tile.y)"
    }

    /// A short trail through the middle of `tile`, which puts the tile, and
    /// the ones around it, in the trail's corridor.
    private static func trail(across tile: VectorTileAddress) -> [CLLocationCoordinate2D] {
        let west = SlippyTileMath.lon(x: tile.x, z: tile.z)
        let east = SlippyTileMath.lon(x: tile.x + 1, z: tile.z)
        let north = SlippyTileMath.lat(y: tile.y, z: tile.z)
        let south = SlippyTileMath.lat(y: tile.y + 1, z: tile.z)
        let latitude = (north + south) / 2
        return [
            CLLocationCoordinate2D(latitude: latitude, longitude: west + (east - west) * 0.25),
            CLLocationCoordinate2D(latitude: latitude, longitude: west + (east - west) * 0.75),
        ]
    }

    /// Slovenia, opened as an install records it, its archive holding
    /// ``inside`` and ``beside`` and nothing else.
    private func slovenia(in directory: URL, minimumZoom: Int = 0, recorded: Bool = true) throws
        -> OfflineCountryArchives.Country {
        let bytes = OfflineCountryFixture.archive(
            [Self.inside: Data("tile".utf8), Self.beside: Data("tile".utf8)],
            maximumZoom: max(Self.inside.z, minimumZoom),
            minimumZoom: minimumZoom
        )
        // A file of its own each time, so one opened earlier is not written over.
        let file = directory.appending(path: "SI-\(UUID().uuidString).pmtiles")
        try bytes.write(to: file)
        let country = OfflineCountryFixture.country(bytes: bytes)
        return OfflineCountryArchives.Country(
            id: "SI",
            bounds: country.bounds,
            basemap: try PMTilesArchive(contentsOf: file),
            extras: nil,
            record: recorded ? OfflineCountryStore.Record(country: country, installedAt: .now) : nil
        )
    }

    /// The tile-thread path: the tile has been drawn, so its bytes are in the
    /// browsing cache, and the store decides whether to keep them.
    private func browse(_ key: String, at tile: VectorTileAddress) async throws {
        try sandbox.browse(key: key)
        let store = sandbox.store
        await offMain { store.considerPersisting(key: key, z: tile.z, x: tile.x, y: tile.y) }
    }

    @Test("a tile is kept until a country that holds it is downloaded, and left in the cache after")
    func countryTileIsLeftInTheCache() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            sandbox.store.setActiveHike(id: hikeID, route: Self.trail(across: Self.inside), knownKeys: [])
            let before = Self.key(Self.inside)
            try await browse(before, at: Self.inside)
            #expect(sandbox.isSaved(before), "precondition: with no country, the tile is the hike's to keep")

            archives.replace(with: [try slovenia(in: directory)])
            let after = Self.key(Self.beside)
            try await browse(after, at: Self.beside)

            #expect(!sandbox.isSaved(after), "the country draws this ground with no signal already")
            #expect(sandbox.isBrowsed(after), "and the copy the map drew is still ordinary cache")
            #expect(sandbox.store.drainPendingKeys(for: hikeID) == [before], "nor is it claimed for the hike")
        }
    }

    /// Only the OpenHikes map is cut by country. A country that holds a
    /// trail's ground says nothing of the same ground on another map, which
    /// has no other way to be kept.
    @Test("another map's tile of a downloaded country's ground is still kept")
    func otherMapsAreStillKept() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            archives.replace(with: [try slovenia(in: directory)])
            sandbox.store.setActiveHike(id: hikeID, route: Self.trail(across: Self.inside), knownKeys: [])

            let key = Self.key(Self.inside, provider: "thunderforest_outdoors")
            try await browse(key, at: Self.inside)

            #expect(sandbox.isSaved(key))
            #expect(sandbox.store.drainPendingKeys(for: hikeID) == [key])
        }
    }

    /// The country's outline holds the tile, but its archive has nothing
    /// there, so the map drew it from the server. Left in the cache, it would
    /// be gone offline once the cache was trimmed, with the country no help.
    @Test("a tile the country's archive lacks is still kept")
    func archiveGapIsStillKept() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            archives.replace(with: [try slovenia(in: directory)])
            sandbox.store.setActiveHike(id: hikeID, route: Self.trail(across: Self.gap), knownKeys: [])

            let key = Self.key(Self.gap)
            try await browse(key, at: Self.gap)

            #expect(sandbox.isSaved(key))
            #expect(sandbox.store.drainPendingKeys(for: hikeID) == [key])
        }
    }

    @Test("a tile outside every downloaded country is still kept")
    func groundOutsideIsStillKept() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            archives.replace(with: [try slovenia(in: directory)])
            sandbox.store.setActiveHike(id: hikeID, route: Self.trail(across: Self.outside), knownKeys: [])

            let key = Self.key(Self.outside)
            try await browse(key, at: Self.outside)

            #expect(sandbox.isSaved(key))
        }
    }

    /// The question errs toward keeping. An answer of yes for a tile the
    /// country could not draw would leave that ground with no map offline
    /// from either.
    @Test("a country holds a tile only inside its outline, where its archive has it, once it has a record")
    func holdsOnlyWhatItCanDraw() async throws {
        try await OfflineCountryFixture.withDirectory { directory in
            #expect(!archives.holds(Self.inside, deepest: Self.deepest), "no country is downloaded")

            archives.replace(with: [try slovenia(in: directory)])
            #expect(archives.holds(Self.inside, deepest: Self.deepest))
            #expect(!archives.holds(Self.gap, deepest: Self.deepest), "its archive has no tile there")
            #expect(!archives.holds(Self.outside, deepest: Self.deepest))
            // Zoom 16, drawn from the zoom-14 tile around it: the deepest the
            // archive reaches.
            let closer = VectorTileAddress(z: 16, x: Self.inside.x * 4 + 1, y: Self.inside.y * 4 + 2)
            #expect(archives.holds(closer, deepest: Self.deepest), "a closer tile is drawn from the one around it")
            let closerInGap = VectorTileAddress(z: 16, x: Self.gap.x * 4, y: Self.gap.y * 4)
            #expect(!archives.holds(closerInGap, deepest: Self.deepest))

            archives.replace(with: [try slovenia(in: directory, minimumZoom: 15)])
            #expect(!archives.holds(Self.inside, deepest: Self.deepest), "its files start below this zoom")

            archives.replace(with: [try slovenia(in: directory, recorded: false)])
            #expect(!archives.holds(Self.inside, deepest: Self.deepest), "with no record there is no outline to ask")
        }
    }
}
