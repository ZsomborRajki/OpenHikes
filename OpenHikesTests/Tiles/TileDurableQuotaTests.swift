//
//  TileDurableQuotaTests.swift
//  OpenHikesTests
//
//  The 100 MB per-device ceiling Stadia's terms set, and what happens at it.
//
//  Every suite here builds its own ``TileSandbox`` with a shrunken ceiling —
//  `durableByteLimitScale` — so the boundary is reachable with a few tiles
//  rather than a hundred megabytes of them. The ratio is what is under test,
//  not the absolute figure; that one is asserted in `TileProviderTests`.
//

import Foundation
@testable import OpenHikes
import Testing

@Suite("Durable tile quota")
struct TileDurableQuotaTests {
    /// Stadia's real ceiling divided by this leaves room for exactly three
    /// fixture tiles, so the fourth is the one that has to be refused.
    nonisolated private static var scaleForThreeTiles: Double {
        Double(TileStore.tileByteCount * 3) / Double(TileProvider.stadiaDurableByteLimit)
    }

    nonisolated private static let stadia = TileProvider.stadiaOutdoors.id
    nonisolated private static let osm = TileProvider.openStreetMap.id

    nonisolated private static func key(_ providerID: String, _ index: Int) -> String {
        "\(providerID)/14/\(8000 + index)/5000@2x"
    }

    // MARK: Ownership of a tile file

    /// The whole quota rests on being able to tell whose tile a file is from
    /// its flattened name, and the ids share prefixes.
    @Test("a durable file is attributed to the right provider")
    func fileOwnership() {
        #expect(TileCache.providerID(forKey: "stadia_outdoors/14/1/2@2x") == "stadia_outdoors")
        #expect(TileCache.providerID(forDiskName: "stadia_outdoors_14_1_2_2x") == "stadia_outdoors")
        #expect(TileCache.providerID(forDiskName: "osm_14_1_2_2x") == "osm")
        #expect(TileCache.providerID(forDiskName: "thunderforest_outdoors_14_1_2_2x")
            == "thunderforest_outdoors")
        #expect(TileCache.providerID(forDiskName: "not_a_provider_14_1_2_2x") == nil)
    }

    @Test("only a capped provider has a ceiling")
    func ceilingsFollowTheCatalog() async {
        let sandbox = TileSandbox()
        await offMain {
            #expect(sandbox.cache.durableByteLimit(forProviderID: Self.stadia) != nil)
            #expect(sandbox.cache.durableByteLimit(forProviderID: Self.osm) == nil)
            #expect(sandbox.cache.durableByteLimit(forProviderID: nil) == nil)
            #expect(sandbox.cache.durableSpace(forProviderID: Self.osm) == nil)
        }
    }

    // MARK: Measurement

    @Test("measurement counts only the capped provider's own durable tiles")
    func measurementIsPerProvider() async throws {
        let sandbox = TileSandbox()
        try sandbox.save(key: Self.key(Self.stadia, 0))
        try sandbox.save(key: Self.key(Self.stadia, 1))
        try sandbox.save(key: Self.key(Self.osm, 0))
        // A browsed tile is not durable and must not count against a ceiling
        // that only governs what is kept.
        try sandbox.browse(key: Self.key(Self.stadia, 2))

        let measured = await offMain { sandbox.cache.durableSpace(forProviderID: Self.stadia) }
        #expect(try #require(measured).used == TileStore.tileByteCount * 2)
    }

    @Test("deleting durable tiles re-measures rather than drifting")
    func deletionInvalidatesTheMeasurement() async throws {
        let sandbox = TileSandbox()
        let doomed = Self.key(Self.stadia, 0)
        try sandbox.save(key: doomed)
        try sandbox.save(key: Self.key(Self.stadia, 1))

        _ = await offMain { sandbox.cache.durableSpace(forProviderID: Self.stadia) }
        await offMain { sandbox.cache.removeTiles(forKeys: [doomed]) }

        let after = await offMain { sandbox.cache.durableSpace(forProviderID: Self.stadia) }
        #expect(try #require(after).used == TileStore.tileByteCount)
    }

    // MARK: Refusal

    /// Auto-save's half of the policy: at the ceiling a passively browsed tile
    /// is refused, and nothing already saved is touched.
    @Test("a browsed tile is refused once the ceiling is reached, and nothing is evicted")
    func autoSaveRefusesAtTheCeiling() async throws {
        let sandbox = TileSandbox(durableByteLimitScale: Self.scaleForThreeTiles)
        let saved = (0..<3).map { Self.key(Self.stadia, $0) }
        for key in saved { try sandbox.save(key: key) }

        let overflow = Self.key(Self.stadia, 3)
        try sandbox.browse(key: overflow)

        let promoted = await offMain { sandbox.cache.promoteCachedTile(forKey: overflow) }
        #expect(!promoted)
        #expect(!sandbox.isSaved(overflow))
        // Still drawable, still in the browsing tier: refusing to *keep* a
        // tile is not the same as refusing to show it.
        #expect(sandbox.isBrowsed(overflow))
        for key in saved { #expect(sandbox.isSaved(key)) }
    }

    /// An uncapped provider is unaffected by any of this, at any size.
    @Test("an uncapped provider is never refused")
    func uncappedProviderIsUnaffected() async throws {
        let sandbox = TileSandbox(durableByteLimitScale: Self.scaleForThreeTiles)
        for index in 0..<5 { try sandbox.save(key: Self.key(Self.osm, index)) }

        let extra = Self.key(Self.osm, 5)
        try sandbox.browse(key: extra)
        let promoted = await offMain { sandbox.cache.promoteCachedTile(forKey: extra) }
        #expect(promoted)
        #expect(sandbox.isSaved(extra))
    }

    /// Promoting a tile that is already durable must not spend the ceiling a
    /// second time, or a re-browsed route would exhaust it without adding a
    /// single byte to disk.
    @Test("re-promoting a saved tile doesn't double-count it")
    func rePromotionIsIdempotent() async throws {
        let sandbox = TileSandbox(durableByteLimitScale: Self.scaleForThreeTiles)
        let key = Self.key(Self.stadia, 0)
        try sandbox.save(key: key)
        try sandbox.browse(key: key)

        for _ in 0..<6 {
            #expect(await offMain { sandbox.cache.promoteCachedTile(forKey: key) })
        }

        let measured = await offMain { sandbox.cache.durableSpace(forProviderID: Self.stadia) }
        #expect(try #require(measured).used == TileStore.tileByteCount)
    }

    // MARK: Reclaim

    @Test("the download being made is never a reclaim candidate")
    func reclaimProtectsThePlannedKeys() async throws {
        let sandbox = TileSandbox(durableByteLimitScale: Self.scaleForThreeTiles)
        let keep = Self.key(Self.stadia, 0)
        let evictable = Self.key(Self.stadia, 1)
        try sandbox.save(key: keep)
        try sandbox.save(key: evictable)

        let reclaimable = await offMain {
            sandbox.cache.reclaimableDurableBytes(
                forProviderID: Self.stadia,
                protecting: [keep]
            )
        }
        #expect(reclaimable == TileStore.tileByteCount)
    }

    @Test("reclaim takes the oldest tiles first")
    func reclaimIsOldestFirst() async throws {
        let sandbox = TileSandbox(durableByteLimitScale: Self.scaleForThreeTiles)
        let oldest = Self.key(Self.stadia, 0)
        let middle = Self.key(Self.stadia, 1)
        let newest = Self.key(Self.stadia, 2)
        try sandbox.save(key: oldest)
        try sandbox.save(key: middle)
        try sandbox.save(key: newest)
        try sandbox.age(key: oldest, byDays: 3)
        try sandbox.age(key: middle, byDays: 2)

        let freed = await offMain {
            sandbox.cache.reclaimDurableBytes(
                forProviderID: Self.stadia,
                protecting: [],
                byteCount: TileStore.tileByteCount
            )
        }

        #expect(freed == TileStore.tileByteCount)
        #expect(!sandbox.isSaved(oldest))
        #expect(sandbox.isSaved(middle))
        #expect(sandbox.isSaved(newest))
    }

    @Test("reclaim never crosses into another provider's tiles")
    func reclaimStaysInsideTheProvider() async throws {
        let sandbox = TileSandbox(durableByteLimitScale: Self.scaleForThreeTiles)
        let stadiaKey = Self.key(Self.stadia, 0)
        let osmKey = Self.key(Self.osm, 0)
        try sandbox.save(key: stadiaKey)
        try sandbox.save(key: osmKey)
        try sandbox.age(key: osmKey, byDays: 30)

        let freed = await offMain {
            sandbox.cache.reclaimDurableBytes(
                forProviderID: Self.stadia,
                protecting: [],
                byteCount: TileStore.tileByteCount * 4
            )
        }

        #expect(freed == TileStore.tileByteCount)
        #expect(!sandbox.isSaved(stadiaKey))
        #expect(sandbox.isSaved(osmKey))
    }

    /// Reclaiming has to free the ceiling as well as the disk, or the next
    /// write would still be refused against a stale total.
    @Test("reclaimed bytes come back off the measured total")
    func reclaimFreesTheCeiling() async throws {
        let sandbox = TileSandbox(durableByteLimitScale: Self.scaleForThreeTiles)
        let saved = (0..<3).map { Self.key(Self.stadia, $0) }
        for key in saved { try sandbox.save(key: key) }

        let overflow = Self.key(Self.stadia, 3)
        try sandbox.browse(key: overflow)
        #expect(!(await offMain { sandbox.cache.promoteCachedTile(forKey: overflow) }))

        _ = await offMain {
            sandbox.cache.reclaimDurableBytes(
                forProviderID: Self.stadia,
                protecting: [overflow],
                byteCount: TileStore.tileByteCount
            )
        }

        #expect(await offMain { sandbox.cache.promoteCachedTile(forKey: overflow) })
        #expect(sandbox.isSaved(overflow))
    }

    // MARK: Launch enforcement

    /// What an install that predates the ceiling looks like: already over, with
    /// no write to refuse. This is the one path that evicts without asking,
    /// because there is nothing to ask about — the tiles are already in breach.
    @Test("a store that is already over the ceiling is trimmed at launch")
    func launchEnforcementTrimsAnOverfullStore() async throws {
        let sandbox = TileSandbox(durableByteLimitScale: Self.scaleForThreeTiles)
        for index in 0..<8 {
            let key = Self.key(Self.stadia, index)
            try sandbox.save(key: key)
            try sandbox.age(key: key, byDays: Double(8 - index))
        }
        let osmKey = Self.key(Self.osm, 0)
        try sandbox.save(key: osmKey)
        try sandbox.age(key: osmKey, byDays: 40)

        _ = await offMain { sandbox.cache.enforceDurableByteLimits() }

        let measured = try #require(
            await offMain { sandbox.cache.durableSpace(forProviderID: Self.stadia) }
        )
        #expect(measured.used <= measured.limit)
        // The newest tiles are the ones kept.
        #expect(sandbox.isSaved(Self.key(Self.stadia, 7)))
        #expect(!sandbox.isSaved(Self.key(Self.stadia, 0)))
        // An uncapped provider is not swept by this at all.
        #expect(sandbox.isSaved(osmKey))
    }

    @Test("launch enforcement leaves a store under the ceiling alone")
    func launchEnforcementIsANoOpUnderTheCeiling() async throws {
        let sandbox = TileSandbox(durableByteLimitScale: Self.scaleForThreeTiles)
        let saved = (0..<2).map { Self.key(Self.stadia, $0) }
        for key in saved { try sandbox.save(key: key) }

        _ = await offMain { sandbox.cache.enforceDurableByteLimits() }

        for key in saved { #expect(sandbox.isSaved(key)) }
    }
}
