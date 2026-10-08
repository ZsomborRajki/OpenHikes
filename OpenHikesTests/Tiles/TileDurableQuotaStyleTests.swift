//
//  TileDurableQuotaStyleTests.swift
//  OpenHikesTests
//
//  Stadia's 100 MB is one ceiling for every Stadia tile on the device, so it
//  is shared by Stadia Outdoors and Stamen Terrain. Every case here puts both
//  styles' tiles on disk together: a total kept per style would pass each of
//  `TileDurableQuotaTests` and still let the device hold 200 MB.
//

import Foundation
@testable import OpenHikes
import Testing

@Suite("Durable tile quota across Stadia styles")
struct TileDurableQuotaStyleTests {
    /// Stadia's real ceiling divided by this leaves room for exactly three
    /// fixture tiles.
    nonisolated private static var scaleForThreeTiles: Double {
        Double(TileStore.tileByteCount * 3) / Double(TileProvider.stadiaDurableByteLimit)
    }

    /// Room for six fixture tiles: four of each style is under it per style
    /// and over it together.
    nonisolated private static var scaleForSixTiles: Double {
        Double(TileStore.tileByteCount * 6) / Double(TileProvider.stadiaDurableByteLimit)
    }

    nonisolated private static let stadia = TileProvider.stadiaOutdoors.id
    nonisolated private static let terrain = TileProvider.stamenTerrain.id
    nonisolated private static let osm = TileProvider.openStreetMap.id

    nonisolated private static func key(_ providerID: String, _ index: Int) -> String {
        "\(providerID)/14/\(8000 + index)/5000@2x"
    }

    /// The clause the quota exists for counts every Stadia tile on the device,
    /// so a style's space is measured over both styles' files.
    @Test("measurement counts every Stadia style against one total")
    func measurementSpansStyles() async throws {
        let sandbox = TileSandbox()
        try sandbox.save(key: Self.key(Self.stadia, 0))
        try sandbox.save(key: Self.key(Self.terrain, 0))
        try sandbox.save(key: Self.key(Self.terrain, 1))
        try sandbox.save(key: Self.key(Self.osm, 0))

        for provider in [Self.stadia, Self.terrain] {
            let measured = await offMain { sandbox.cache.durableSpace(forProviderID: provider) }
            #expect(try #require(measured).used == TileStore.tileByteCount * 3)
        }
    }

    /// The breach this prevents: with a total per style, a device full of
    /// Outdoors tiles would still have had a second 100 MB for Terrain.
    @Test("one style is refused once the other has filled the shared ceiling")
    func otherStyleFillsTheCeiling() async throws {
        let sandbox = TileSandbox(durableByteLimitScale: Self.scaleForThreeTiles)
        for index in 0..<3 { try sandbox.save(key: Self.key(Self.stadia, index)) }

        let overflow = Self.key(Self.terrain, 0)
        try sandbox.browse(key: overflow)

        #expect(!(await offMain { sandbox.cache.promoteCachedTile(forKey: overflow) }))
        #expect(!sandbox.isSaved(overflow))
        #expect(await offMain { sandbox.cache.isDurableLimitReached(forKey: overflow) })
    }

    /// A Terrain download that does not fit is short of the *shared* space,
    /// so the oldest Stadia tiles go whichever style they were saved in —
    /// and the download's own tiles still never do.
    @Test("a reclaim for one style may take the other style's tiles")
    func reclaimSpansStyles() async throws {
        let sandbox = TileSandbox(durableByteLimitScale: Self.scaleForThreeTiles)
        let oldOutdoors = Self.key(Self.stadia, 0)
        let ownTerrain = Self.key(Self.terrain, 0)
        try sandbox.save(key: oldOutdoors)
        try sandbox.save(key: ownTerrain)
        try sandbox.age(key: oldOutdoors, byDays: 5)
        try sandbox.age(key: ownTerrain, byDays: 10)

        let reclaimable = await offMain {
            sandbox.cache.reclaimableDurableBytes(forProviderID: Self.terrain, protecting: [ownTerrain])
        }
        #expect(reclaimable == TileStore.tileByteCount)

        let freed = await offMain {
            sandbox.cache.reclaimDurableBytes(
                forProviderID: Self.terrain,
                protecting: [ownTerrain],
                byteCount: TileStore.tileByteCount
            )
        }
        #expect(freed == TileStore.tileByteCount)
        #expect(!sandbox.isSaved(oldOutdoors))
        #expect(sandbox.isSaved(ownTerrain))
    }

    /// What a build that counted the styles apart could leave behind: each
    /// style under the ceiling on its own, both together over it. The launch
    /// trim has to see the sum, and take the oldest tiles across both.
    @Test("the launch trim brings both styles together under one ceiling")
    func launchTrimSpansStyles() async throws {
        let sandbox = TileSandbox(durableByteLimitScale: Self.scaleForSixTiles)
        // Interleaved ages, so the oldest tiles are split between the styles.
        for index in 0..<4 {
            let outdoorsKey = Self.key(Self.stadia, index)
            let terrainKey = Self.key(Self.terrain, index)
            try sandbox.save(key: outdoorsKey)
            try sandbox.save(key: terrainKey)
            try sandbox.age(key: outdoorsKey, byDays: Double(20 - index * 2))
            try sandbox.age(key: terrainKey, byDays: Double(19 - index * 2))
        }

        let freed = await offMain { sandbox.cache.enforceDurableByteLimits() }
        #expect(freed > 0)

        let measured = try #require(
            await offMain { sandbox.cache.durableSpace(forProviderID: Self.terrain) }
        )
        #expect(measured.used <= measured.limit)
        // The two oldest — one of each style — are gone; the newest of each stay.
        #expect(!sandbox.isSaved(Self.key(Self.stadia, 0)))
        #expect(!sandbox.isSaved(Self.key(Self.terrain, 0)))
        #expect(sandbox.isSaved(Self.key(Self.stadia, 3)))
        #expect(sandbox.isSaved(Self.key(Self.terrain, 3)))
    }
}
