//
//  OfflineCountryTiles.swift
//  OpenHikes
//
//  The downloaded countries, as the map draws from them: their archives,
//  opened, and the drawing of a tile out of them. ``TileCache`` asks here
//  before it asks the network policy, so a country draws with no signal, and
//  before it asks the tile server, so a country costs the server nothing once
//  it is down. A tile no country holds goes on to the server as it always
//  did.
//
//  The drawing is the one ``VectorTileClient`` does for a tile off the
//  server — the same rasterizer, language and heights — so a tile drawn from
//  a country is the tile the server's bytes would have drawn.
//
//  The cache files a drawn tile under the provider's key, which says nothing
//  of the build it was drawn from, so a tile drawn before a country's build
//  was installed would otherwise answer for a week in place of the new one.
//  ``OfflineCountryArchives/redraws(_:drawnAt:)`` is what has the cache draw
//  it again; it reads outlines and dates, never a file, so the map's draw
//  pass may ask it.
//

import Foundation
import OpenHikesData
import os
import Synchronization

/// The archives of every downloaded country, readable from any thread.
nonisolated final class OfflineCountryArchives: Sendable {
    /// The one the app's tile cache reads, which the countries' model fills.
    static let shared = OfflineCountryArchives()

    struct Country: Sendable {
        let id: String
        let bounds: OfflineCountryManifest.Bounds
        /// To zoom 14, and the extras drawn into it.
        let basemap: PMTilesArchive
        let extras: PMTilesArchive?
        /// What it was installed from: the outline, the build and when.
        /// `nil` draws from it all the same, and redraws nothing.
        var record: OfflineCountryStore.Record?
        /// Zoom 15 and its extras, where *Extra Detail* brought them.
        var detail: PMTilesArchive?
        var detailExtras: PMTilesArchive?
    }

    /// What a country holds for a tile: the archive tile it is drawn from,
    /// and that tile's bytes.
    struct Found: Sendable {
        let dataTile: VectorTileAddress
        let basemap: Data
        let extras: Data?
    }

    private static let logger = Logger(subsystem: "OpenHikes", category: "OfflineCountries")
    private let countries = Mutex<[Country]>([])
    /// When each country's build took the place of another one here, this
    /// launch. Later than its install by as long as opening it took, and a
    /// tile drawn in between came out of the build it replaced.
    private let replacedAt = Mutex<[String: Date]>([:])

    var isEmpty: Bool { countries.withLock { $0.isEmpty } }

    func replace(with countries: [Country]) {
        let now = Date()
        self.countries.withLock { held in
            let builds = Dictionary(
                held.compactMap { country in country.record.map { (country.id, $0.country.build) } },
                uniquingKeysWith: { first, _ in first }
            )
            replacedAt.withLock { stamps in
                for country in countries {
                    guard let build = country.record?.country.build,
                          let previous = builds[country.id],
                          previous != build
                    else { continue }
                    stamps[country.id] = now
                }
            }
            held = countries
        }
    }

    /// Whether a tile drawn at `storedAt` is to be drawn again: a country
    /// whose outline holds the middle of `target` was installed after it, so
    /// the tile came from an older build or from the server. The middle,
    /// because a country is cut along its outline grown by a margin, so a
    /// tile whose middle the outline holds is one the country has.
    func redraws(_ target: VectorTileAddress, drawnAt storedAt: Date) -> Bool {
        let held = countries.withLock { $0 }
        let stamps = replacedAt.withLock { $0 }
        let newer = held.compactMap { country -> OfflineCountryStore.Record? in
            guard let record = country.record else { return nil }
            let since = max(record.installedAt, stamps[country.id] ?? record.installedAt)
            return since > storedAt ? record : nil
        }
        guard !newer.isEmpty else { return false }
        let middle = Self.middle(of: target)
        return newer.contains { $0.country.contains(longitude: middle.longitude, latitude: middle.latitude) }
    }

    /// Whether a downloaded country draws `target` with no signal: its
    /// outline holds the tile's middle, by the rule ``redraws(_:drawnAt:)``
    /// reads, and the files ``tile(for:deepest:extrasFrom:)`` would draw it
    /// from, to `deepest`, have the tile it would be drawn from. Read from
    /// the archives' directories, never a tile's bytes.
    ///
    /// What asks this keeps a tile too many and never one too few, so every
    /// doubt answers no: a tile on a country's edge, held only by the margin
    /// it was cut with; a country opened with no record; a zoom its files do
    /// not reach; a gap in its archive, where the map fell back to the
    /// server; and a directory that could not be read.
    func holds(_ target: VectorTileAddress, deepest: Int) -> Bool {
        let held = countries.withLock { $0 }
        guard !held.isEmpty else { return false }
        let middle = Self.middle(of: target)
        return held.contains { country in
            guard country.record?.country.contains(longitude: middle.longitude, latitude: middle.latitude) == true
            else { return false }
            return [country.detail, country.basemap].contains { basemap in
                guard let basemap, let dataTile = Self.dataTile(of: target, deepest: deepest, in: basemap) else {
                    return false
                }
                return (try? basemap.contains(z: dataTile.z, x: dataTile.x, y: dataTile.y)) == true
            }
        }
    }

    private static func middle(of tile: VectorTileAddress) -> (longitude: Double, latitude: Double) {
        let size = Double(1 << tile.z)
        return (
            (Double(tile.x) + 0.5) / size * 360 - 180,
            latitude(ofRow: (Double(tile.y) + 0.5) / size)
        )
    }

    /// The bytes the first area that holds `target` has for it, from the
    /// tile at the deepest zoom both it and `deepest` reach, or `nil` where
    /// no area holds it. Zoom 15 and closer come from the area's zoom-15
    /// files where it has them, and from its zoom-14 tile around them where
    /// it does not.
    ///
    /// The extras come from the same files, from `extrasFrom` down, so a
    /// tile drawn offline is drawn from one build. A file that cannot be read
    /// is passed over, as an area that does not hold the tile is.
    func tile(for target: VectorTileAddress, deepest: Int, extrasFrom extrasZoom: Int?) -> Found? {
        let held = countries.withLock { $0 }
        for country in held {
            guard Self.box(of: target, meets: country.bounds) else { continue }
            let layers = [(country.detail, country.detailExtras), (country.basemap, country.extras)]
            for case let (basemap?, extras) in layers where target.z >= Int(basemap.header.minimumZoom) {
                if let found = Self.tile(
                    for: target, deepest: deepest, extrasFrom: extrasZoom, in: basemap, extras, of: country
                ) {
                    return found
                }
            }
        }
        return nil
    }

    private static func tile(
        for target: VectorTileAddress,
        deepest: Int,
        extrasFrom extrasZoom: Int?,
        in basemap: PMTilesArchive,
        _ extras: PMTilesArchive?,
        of country: Country
    ) -> Found? {
        guard let dataTile = dataTile(of: target, deepest: deepest, in: basemap) else { return nil }
        do {
            guard let bytes = try basemap.tile(z: dataTile.z, x: dataTile.x, y: dataTile.y) else { return nil }
            var added: Data?
            if let extrasZoom, dataTile.z >= extrasZoom {
                added = try? extras?.tile(z: dataTile.z, x: dataTile.x, y: dataTile.y)
            }
            return Found(dataTile: dataTile, basemap: bytes, extras: added)
        } catch {
            let reason = String(describing: error)
            logger.error("Country \(country.id, privacy: .public) unreadable: \(reason, privacy: .public)")
            return nil
        }
    }

    /// The archive tile `target` is drawn from: itself, or the one around it
    /// at the deepest zoom both `basemap` and `deepest` reach. `nil` where
    /// that zoom is above the archive's first.
    private static func dataTile(
        of target: VectorTileAddress,
        deepest: Int,
        in basemap: PMTilesArchive
    ) -> VectorTileAddress? {
        let zoom = min(target.z, deepest, Int(basemap.header.maximumZoom))
        guard zoom >= Int(basemap.header.minimumZoom) else { return nil }
        let shift = target.z - zoom
        return VectorTileAddress(z: zoom, x: target.x >> shift, y: target.y >> shift)
    }

    /// Whether the tile's ground meets `bounds` at all.
    static func box(of tile: VectorTileAddress, meets bounds: OfflineCountryManifest.Bounds) -> Bool {
        let size = Double(1 << tile.z)
        let west = Double(tile.x) / size * 360 - 180
        let east = Double(tile.x + 1) / size * 360 - 180
        let north = latitude(ofRow: Double(tile.y) / size)
        let south = latitude(ofRow: Double(tile.y + 1) / size)
        return west <= bounds.east && east >= bounds.west && south <= bounds.north && north >= bounds.south
    }

    private static func latitude(ofRow fraction: Double) -> Double {
        atan(sinh(.pi * (1 - 2 * fraction))) * 180 / .pi
    }
}

/// Draws a provider's tile out of the downloaded countries.
nonisolated final class OfflineCountryDrawing: Sendable {
    private let sources: VectorTileArchives
    private let archives: OfflineCountryArchives
    private let language: String

    init(
        sources: VectorTileArchives,
        archives: OfflineCountryArchives,
        language: String = VectorTileLabels.appLanguage
    ) {
        self.sources = sources
        self.archives = archives
        self.language = language
    }

    /// Whether the cache's copy of the tile `key` names, drawn at `storedAt`,
    /// is to be drawn again out of a country installed since. See
    /// ``OfflineCountryArchives/redraws(_:drawnAt:)``.
    func redraws(_ key: String, drawnAt storedAt: Date) -> Bool {
        guard !archives.isEmpty,
              let named = TileCacheKey.named(key),
              sources.source(for: named.providerID) != nil
        else { return false }
        return archives.redraws(VectorTileAddress(z: named.z, x: named.x, y: named.y), drawnAt: storedAt)
    }

    /// Whether a downloaded country draws the tile `key` names, for a
    /// provider drawn from vector tiles: any other provider's tile of the
    /// same ground is no country's. See
    /// ``OfflineCountryArchives/holds(_:deepest:)``.
    func holds(_ key: String) -> Bool {
        guard !archives.isEmpty,
              let named = TileCacheKey.named(key),
              let source = sources.source(for: named.providerID)
        else { return false }
        return archives.holds(VectorTileAddress(z: named.z, x: named.x, y: named.y), deepest: source.maximumZ)
    }

    /// The tile `key` names, drawn out of a downloaded country as PNG bytes,
    /// or `nil` when the provider draws no vector tiles, no country holds the
    /// tile, or it could not be drawn.
    func png(forKey key: String) -> Data? {
        guard !archives.isEmpty,
              let named = TileCacheKey.named(key),
              let source = sources.source(for: named.providerID)
        else { return nil }
        let target = VectorTileAddress(z: named.z, x: named.x, y: named.y)
        guard let found = archives.tile(
            for: target,
            deepest: source.maximumZ,
            extrasFrom: source.extras?.minimumZ
        ) else { return nil }
        let names = VectorTileRasterizer.layerNames
        let keys = VectorTileRasterizer.propertyKeys(language: language)
        guard var tile = try? MapboxVectorTile(data: found.basemap, layerNames: names, propertyKeys: keys) else {
            return nil
        }
        if let extras = found.extras,
           let added = try? MapboxVectorTile(data: extras, layerNames: names, propertyKeys: keys) {
            tile = tile.merging(added)
        }
        return VectorTileRasterizer.png(
            of: tile,
            from: found.dataTile,
            drawing: target,
            language: language,
            height: { HikeFormat.elevation(Measurement(value: $0, unit: .meters)) }
        )
    }
}
