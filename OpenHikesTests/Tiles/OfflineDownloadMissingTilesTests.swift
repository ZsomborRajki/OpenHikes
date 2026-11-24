//
//  OfflineDownloadMissingTilesTests.swift
//  OpenHikesTests
//
//  A resumed download skips what a previous run claimed, and a claim is a row
//  in the store while the tile is a file beside it. The two can part: the
//  durable directory is kept out of the device backup, so a restored phone
//  brings back a hike's partial record without one of its tiles. A retry
//  that took the record at its word skipped every one of them and could call
//  the map saved. These hold the retry to the disk: a claimed tile is skipped
//  only once its file is found, through the real check over a sandboxed
//  cache.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import Testing

@MainActor
@Suite("Resuming a download whose saved tiles are gone")
struct OfflineDownloadMissingTilesTests {
    private static let source = ActiveTileSource(
        providerID: TileProvider.stadiaOutdoors.id,
        urlTemplate: "https://example.invalid/{z}/{x}/{y}.png",
        maximumZ: 14
    )

    private actor SaveLog {
        private(set) var saved: [String] = []

        func save(_ key: String) -> Bool {
            saved.append(key)
            return true
        }
    }

    /// Holds the disk check until the test lets it answer, so a cancel can
    /// land while it is out.
    @MainActor
    private final class HeldCheck {
        private var waiter: CheckedContinuation<Void, Never>?
        private(set) var asked: Set<String> = []

        func check(_ keys: Set<String>) async -> Set<String> {
            asked = keys
            await withCheckedContinuation { waiter = $0 }
            return keys
        }

        func release() {
            waiter?.resume()
            waiter = nil
        }
    }

    private func plannedKeys() async throws -> [String] {
        let plan = try await OfflineTileDownloader.plannedTiles(
            for: Fixture.ridgeRoute,
            maxZoom: Self.source.maximumZ,
            providerID: Self.source.providerID
        )
        #expect(plan.tiles.count > 4, "precondition: room for present and missing tiles")
        return plan.tiles.map { $0.cacheKey(providerID: Self.source.providerID) }
    }

    private func downloader(
        log: SaveLog,
        durableKeys: @escaping OfflineTileDownloader.DurableCheck
    ) -> OfflineTileDownloader {
        OfflineTileDownloader(
            gate: TileLoadGate(),
            isOnline: { true },
            quota: .unlimited,
            registry: OfflineDownloadRegistry(),
            durableKeys: durableKeys,
            saveTile: { key, _ in await log.save(key) }
        )
    }

    private func checking(_ sandbox: TileSandbox) -> OfflineTileDownloader.DurableCheck {
        { keys throws(CancellationError) in try await sandbox.cache.durableKeys(among: keys) }
    }

    @Test("a claim whose every tile is gone is downloaded whole")
    func everyClaimedTileMissing() async throws {
        let keys = try await plannedKeys()
        let sandbox = TileSandbox()
        let log = SaveLog()
        let downloader = downloader(log: log, durableKeys: checking(sandbox))

        downloader.start(
            route: Fixture.ridgeRoute,
            source: Self.source,
            alreadySaved: Set(keys.dropLast()),
            claim: Fixture.unrecordedClaim
        )
        await downloader.waitForCurrentRun()

        #expect(downloader.phase == .finished)
        #expect(downloader.completed == downloader.total)
        #expect(await Set(log.saved) == Set(keys))
    }

    @Test("only the claimed tiles still on disk are skipped")
    func someClaimedTilesMissing() async throws {
        let keys = try await plannedKeys()
        let sandbox = TileSandbox()
        let log = SaveLog()
        let claimed = Array(keys.dropLast())
        let present = claimed.enumerated().filter { $0.offset.isMultiple(of: 2) }.map(\.element)
        for key in present { try sandbox.save(key: key) }
        let downloader = downloader(log: log, durableKeys: checking(sandbox))

        downloader.start(
            route: Fixture.ridgeRoute,
            source: Self.source,
            alreadySaved: Set(claimed),
            claim: Fixture.unrecordedClaim
        )
        await downloader.waitForCurrentRun()

        #expect(downloader.phase == .finished)
        #expect(downloader.completed == downloader.total)
        #expect(downloader.total == keys.count)
        #expect(await Set(log.saved) == Set(keys).subtracting(present))
    }

    /// The check runs while the run is still planning, and a cancel there
    /// must leave nothing fetched and nothing advertised.
    @Test("a run cancelled while it checks the disk fetches nothing")
    func cancelledDuringTheCheck() async throws {
        let keys = try await plannedKeys()
        let held = HeldCheck()
        let log = SaveLog()
        let downloader = downloader(log: log) { keys in await held.check(keys) }

        downloader.start(
            route: Fixture.ridgeRoute,
            source: Self.source,
            alreadySaved: Set(keys),
            claim: Fixture.unrecordedClaim
        )
        await settleDelegateHop(until: "the resumed keys to be checked against the disk") {
            !held.asked.isEmpty
        }
        downloader.cancel()
        held.release()
        await downloader.waitForCurrentRun()

        #expect(held.asked == Set(keys))
        #expect(downloader.phase == .idle)
        #expect(downloader.total == 0)
        #expect(await log.saved.isEmpty)
    }

    /// A browsed copy is not the coverage a claim promised, so it does not
    /// count as present.
    @Test("the cache finds only keys with a durable file")
    func cacheReportsDurableFilesOnly() async throws {
        let sandbox = TileSandbox()
        let saved = "\(Self.source.providerID)/14/1/1"
        let browsed = "\(Self.source.providerID)/14/1/2"
        let missing = "\(Self.source.providerID)/14/1/3"
        try sandbox.save(key: saved)
        try sandbox.browse(key: browsed)

        #expect(try await sandbox.cache.durableKeys(among: [saved, browsed, missing]) == [saved])
    }
}
