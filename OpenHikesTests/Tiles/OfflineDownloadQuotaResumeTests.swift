//
//  OfflineDownloadQuotaResumeTests.swift
//  OpenHikesTests
//
//  Drives planning, the quota question and its confirmation together. A
//  correct shortfall helper alone cannot prove a resumed run passes the gap
//  into that helper or keeps it after the hiker agrees to reclaim space.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import Testing

@Suite("Resuming a download against its quota")
struct OfflineDownloadQuotaResumeTests {
    private static let source = ActiveTileSource(
        providerID: TileProvider.stadiaOutdoors.id,
        urlTemplate: "https://example.invalid/{z}/{x}/{y}.png",
        maximumZ: 14
    )

    private actor RunLog {
        private(set) var saved: [String] = []
        private(set) var protectedAtCheck: Set<String> = []
        private(set) var protectedAtReclaim: Set<String> = []
        private(set) var reclaimedBytes: Int64 = 0

        func save(_ key: String) -> Bool {
            saved.append(key)
            return true
        }

        func reclaimable(protecting keys: Set<String>) -> Int64 {
            protectedAtCheck = keys
            return Int64(keys.count) * TileCache.estimatedTileBytes
        }

        func reclaim(protecting keys: Set<String>, bytes: Int64) -> Int64 {
            protectedAtReclaim = keys
            reclaimedBytes += bytes
            return bytes
        }
    }

    private func plannedKeys() async throws -> [String] {
        let plan = try await OfflineTileDownloader.plannedTiles(
            for: Fixture.ridgeRoute,
            maxZoom: Self.source.maximumZ,
            providerID: Self.source.providerID
        )
        #expect(plan.tiles.count > 4, "precondition: leave a gap and some saved coverage")
        return plan.tiles.map { $0.cacheKey(providerID: Self.source.providerID) }
    }

    private func downloader(
        log: RunLog,
        quota: OfflineTileDownloader.QuotaBroker = .unlimited
    ) -> OfflineTileDownloader {
        OfflineTileDownloader(
            gate: TileLoadGate(),
            isOnline: { true },
            quota: quota,
            registry: OfflineDownloadRegistry(),
            saveTile: { key, _ in await log.save(key) }
        )
    }

    @Test("a resumed run with room for its gap finishes without reclaiming")
    func aGapThatFitsDoesNotAsk() async throws {
        let keys = try await plannedKeys()
        let log = RunLog()
        let limit = Int64(keys.count) * TileCache.estimatedTileBytes
        let downloader = downloader(
            log: log,
            quota: .init(
                space: { _ in (limit: limit, used: limit - TileCache.estimatedTileBytes) },
                reclaimable: { _, protected in await log.reclaimable(protecting: protected) },
                reclaim: { _, protected, bytes in await log.reclaim(protecting: protected, bytes: bytes) }
            )
        )

        downloader.start(
            route: Fixture.ridgeRoute,
            source: Self.source,
            alreadySaved: Set(keys.dropLast()),
            claim: Fixture.unrecordedClaim
        )
        await downloader.waitForCurrentRun()

        #expect(downloader.phase == .finished)
        #expect(downloader.completed == keys.count)
        #expect(await log.saved == Array(keys.suffix(1)))
        #expect(await log.reclaimedBytes == 0)
    }

    @Test("confirmation protects the full plan and saves only the resumed gap")
    func confirmationKeepsTheGap() async throws {
        let keys = try await plannedKeys()
        let log = RunLog()
        let limit = Int64(keys.count) * TileCache.estimatedTileBytes
        let downloader = downloader(
            log: log,
            quota: .init(
                space: { _ in (limit: limit, used: limit) },
                reclaimable: { _, protected in await log.reclaimable(protecting: protected) },
                reclaim: { _, protected, bytes in await log.reclaim(protecting: protected, bytes: bytes) }
            )
        )
        downloader.start(
            route: Fixture.ridgeRoute,
            source: Self.source,
            alreadySaved: Set(keys.dropLast(2)),
            claim: Fixture.unrecordedClaim
        )
        await downloader.waitForCurrentRun()

        let shortfall = try #require(downloader.pendingSpaceShortfall)
        #expect(shortfall.bytesToFree == 2 * TileCache.estimatedTileBytes)
        #expect(await log.saved.isEmpty)
        #expect(await log.protectedAtCheck == Set(keys))
        downloader.confirmReclaimingSpace()
        await downloader.waitForCurrentRun()

        #expect(downloader.phase == .finished)
        #expect(downloader.completed == downloader.total)
        #expect(downloader.total == keys.count)
        #expect(await log.saved.count == 2)
        #expect(await Set(log.saved) == Set(keys.suffix(2)))
        #expect(await log.protectedAtReclaim == Set(keys))
        #expect(await log.reclaimedBytes == shortfall.bytesToFree)
        #expect(downloader.completedRecord?.savedTileKeys.isEmpty == true)
    }

    @Test("durable coverage from another hike is not charged again", arguments: [0, 1], [false, true])
    func overlappingCoverageIsNotCharged(missingCount: Int, resuming: Bool) async throws {
        let keys = try await plannedKeys()
        let sandbox = TileSandbox()
        let log = RunLog()
        // The last three tiles are not in this hike's partial record. Some
        // or all already belong to another hike or to passive auto-save.
        for key in keys.dropLast(missingCount) { try sandbox.save(key: key) }
        for key in keys.suffix(missingCount) { try sandbox.browse(key: key) }
        let limit = Int64(keys.count) * TileCache.estimatedTileBytes
        let available = Int64(missingCount) * TileCache.estimatedTileBytes
        let downloader = downloader(
            log: log,
            quota: .init(
                space: { _ in (limit: limit, used: limit - available) },
                reclaimable: { _, protected in await log.reclaimable(protecting: protected) },
                reclaim: { _, protected, bytes in await log.reclaim(protecting: protected, bytes: bytes) },
                additionalBytes: { keys in
                    await offMain { sandbox.cache.estimatedAdditionalDurableBytes(forKeys: keys) }
                }
            )
        )
        downloader.start(
            route: Fixture.ridgeRoute,
            source: Self.source,
            alreadySaved: resuming ? Set(keys.dropLast(3)) : [],
            claim: Fixture.unrecordedClaim
        )
        await downloader.waitForCurrentRun()

        #expect(downloader.phase == .finished)
        #expect(downloader.completed == downloader.total)
        let expected = resuming ? Set(keys.suffix(3)) : Set(keys)
        #expect(await Set(log.saved) == expected)
        #expect(await log.reclaimedBytes == 0)
    }

    @Test("progress counts only saved keys inside the current plan", arguments: [0, 1])
    func progressIgnoresOldCoverage(missingCount: Int) async throws {
        let keys = try await plannedKeys()
        let log = RunLog()
        let downloader = downloader(log: log)
        var alreadySaved = Set(keys.dropLast(missingCount))
        // A partial record survives editing a trail, so it may also hold
        // coverage outside the new plan. Zoom zero is outside this plan.
        alreadySaved.insert("\(Self.source.providerID)/0/0/0")
        downloader.start(
            route: Fixture.ridgeRoute,
            source: Self.source,
            alreadySaved: alreadySaved,
            claim: Fixture.unrecordedClaim
        )
        await downloader.waitForCurrentRun()

        #expect(downloader.phase == .finished)
        #expect(downloader.completed == keys.count)
        #expect(downloader.completed == downloader.total)
        #expect(await log.saved.count == missingCount)
    }
}
