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

    /// Holds each disk check until the test lets it answer, so a cancel, or
    /// a second run, can land while one is out. Every key is answered as
    /// found: what is held here is the timing, not the disk.
    @MainActor
    private final class HeldCheck {
        private var waiters: [CheckedContinuation<Void, Never>] = []
        /// What each check was asked, in the order the runs asked.
        private(set) var asked: [Set<String>] = []

        func check(_ keys: Set<String>) async -> Set<String> {
            asked.append(keys)
            await withCheckedContinuation { waiters.append($0) }
            return keys
        }

        /// Lets the oldest check still held answer.
        func releaseOldest() {
            guard !waiters.isEmpty else { return }
            waiters.removeFirst().resume()
        }
    }

    /// Set by a waiting task just before it parks, in the same turn of the
    /// main actor, so a test can tell the waiter is there without counting
    /// yields.
    @MainActor
    private final class Mark {
        private(set) var isSet = false

        func set() { isSet = true }
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
        held.releaseOldest()
        await downloader.waitForCurrentRun()

        #expect(held.asked == [Set(keys)])
        #expect(downloader.phase == .idle)
        #expect(downloader.total == 0)
        #expect(await log.saved.isEmpty)
    }

    /// The run a cancel left behind answers into a downloader that has moved
    /// on: a second run has started and is checking the disk in its turn.
    /// The stale answer must leave the second run's planning waiters parked.
    /// Released by it, `waitForPlanning()` came back while the second run was
    /// still checking, with no tiles counted.
    @Test("a cancelled run's late check leaves the next run's waiters parked")
    func staleCheckLeavesTheNextRunsWaiters() async throws {
        let keys = try await plannedKeys()
        let held = HeldCheck()
        let log = SaveLog()
        let downloader = downloader(log: log) { keys in await held.check(keys) }
        let start = {
            downloader.start(
                route: Fixture.ridgeRoute,
                source: Self.source,
                alreadySaved: Set(keys),
                claim: Fixture.unrecordedClaim
            )
        }

        start()
        let stale = try #require(downloader.lastRun)
        await settleDelegateHop(until: "the first run to check the disk") { held.asked.count == 1 }
        downloader.cancel()
        start()
        await settleDelegateHop(until: "the second run to check the disk") { held.asked.count == 2 }
        let parked = Mark()
        let waiter = Task {
            parked.set()
            await downloader.waitForPlanning()
            return downloader.total
        }
        await settleDelegateHop(until: "the waiter to park on the second run's planning") { parked.isSet }

        held.releaseOldest()
        await stale.value
        held.releaseOldest()

        let counted = await waiter.value
        #expect(counted == keys.count, "the waiter came back once the second run had counted its plan")
        await downloader.waitForCurrentRun()
        #expect(downloader.phase == .finished)
        #expect(await log.saved.isEmpty)
    }

    /// What a suite gets when it names no check. The test host's tile store
    /// is not a suite's to read, so the default finds nothing, as the app
    /// finds nothing on a disk without the claimed files. No suite can lean on
    /// a claim taken at its word, which the app never takes.
    @Test("in a hosted suite the default check finds no claimed tile")
    func theHostedDefaultFindsNothing() async throws {
        let keys = try await plannedKeys()
        let log = SaveLog()
        let downloader = OfflineTileDownloader(
            gate: TileLoadGate(),
            isOnline: { true },
            quota: .unlimited,
            registry: OfflineDownloadRegistry(),
            saveTile: { key, _ in await log.save(key) }
        )

        downloader.start(
            route: Fixture.ridgeRoute,
            source: Self.source,
            alreadySaved: Set(keys),
            claim: Fixture.unrecordedClaim
        )
        await downloader.waitForCurrentRun()

        #expect(downloader.phase == .finished)
        #expect(await Set(log.saved) == Set(keys))
    }

    /// A browsed copy is not the coverage a claim promised, so it does not
    /// count as present. A tile the cache's own durable save filed does, so
    /// the check and the save agree on where a saved tile is, rather than
    /// only the check and the sandbox's copy of the layout.
    @Test("the cache finds only keys with a durable file")
    func cacheReportsDurableFilesOnly() async throws {
        let sandbox = TileSandbox()
        let saved = "\(Self.source.providerID)/14/1/1"
        let browsed = "\(Self.source.providerID)/14/1/2"
        let missing = "\(Self.source.providerID)/14/1/3"
        let filedByTheCache = "\(Self.source.providerID)/14/1/4"
        try sandbox.save(key: saved)
        try sandbox.browse(key: browsed)
        try sandbox.browse(key: filedByTheCache)
        // An unreachable URL: a browsed copy is moved into the durable tier
        // without a fetch, which is how this one gets there.
        let url = try #require(URL(string: "https://tile.invalid/never-fetched.png"))
        let filed = await sandbox.cache.saveTileDurably(forKey: filedByTheCache, url: url)
        try #require(filed, "precondition: the cache saved the browsed copy durably")

        let found = try await sandbox.cache.durableKeys(among: [saved, browsed, missing, filedByTheCache])
        #expect(found == [saved, filedByTheCache])
    }
}
