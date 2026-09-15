//
//  OfflineQuotaShortfallTests.swift
//  OpenHikesTests
//
//  What a bulk download does when the provider's licensed ceiling cannot hold
//  the map it was asked for: whether it stops to ask, how much it says it
//  needs freeing, and what it tells the hiker when it stopped part-way.
//
//  `TileDurableQuotaTests` beside this one covers the cache's side of the
//  ceiling — reservations, eviction, the launch trim. This covers the
//  *download's* side, which is a different decision made earlier: the cache
//  refuses a tile that would not fit, one tile at a time, and by then the
//  connection has already been spent. ``OfflineTileDownloader/spaceShortfall``
//  is what turns that into a question asked before anything is fetched.
//
//  Every case here drives a ``QuotaBroker`` of its own. The live one reads
//  `TileCache.shared` — the host app's real tile store, which no suite may
//  touch — so a broker is the seam, exactly as its own documentation says.
//

import Foundation
@testable import OpenHikes
import Testing

@Suite("Offline download quota")
struct OfflineQuotaShortfallTests {
    private static let stadia = TileProvider.stadiaOutdoors
    private static let osm = TileProvider.openStreetMap

    private static func source(_ provider: TileProvider) -> ActiveTileSource {
        ActiveTileSource(
            providerID: provider.id,
            urlTemplate: provider.urlTemplate,
            maximumZ: provider.maximumZ
        )
    }

    /// A plan of `count` tiles, distinct so the planned-key set has `count`
    /// members — the download's own tiles are what a reclaim has to protect.
    private static func tiles(_ count: Int) -> [OfflineTileDownloader.Tile] {
        (0..<count).map { OfflineTileDownloader.Tile(z: 14, x: 8000 + $0, y: 5000) }
    }

    /// Bytes for `count` tiles at the estimate the planner sizes with, so a
    /// case can say "room for three" without restating the estimate.
    private static func bytes(forTiles count: Int) -> Int64 {
        Int64(count) * TileCache.estimatedTileBytes
    }

    private static func broker(
        limit: Int64,
        used: Int64,
        reclaimable: Int64 = 0
    ) -> OfflineTileDownloader.QuotaBroker {
        OfflineTileDownloader.QuotaBroker(
            space: { _ in (limit: limit, used: used) },
            reclaimable: { _, _ in reclaimable },
            reclaim: { _, _, bytes in bytes }
        )
    }

    private static func downloader(
        _ quota: OfflineTileDownloader.QuotaBroker
    ) -> OfflineTileDownloader {
        OfflineTileDownloader(quota: quota, saveTile: { _, _ in false })
    }

    // MARK: The budget a capped provider gets

    /// The clamp exists so a plan never asks for more than the terms could
    /// hold. Without it every Stadia download ends "Saved 3,413 of 4,000"
    /// however much space had been freed first.
    @Test("a capped provider's budget is its ceiling, not the standard one")
    func cappedBudgetIsClamped() {
        let capped = OfflineTileDownloader.tileBudget(forProviderID: Self.stadia.id)
        #expect(capped < OfflineTileDownloader.tileBudget)
        #expect(
            capped == Int(TileProvider.stadiaDurableByteLimit / TileCache.estimatedTileBytes)
        )
    }

    @Test("an uncapped provider keeps the standard budget")
    func uncappedBudgetIsStandard() {
        #expect(
            OfflineTileDownloader.tileBudget(forProviderID: Self.osm.id)
                == OfflineTileDownloader.tileBudget
        )
    }

    // MARK: Whether to ask

    /// The ordinary case, and the one that must never prompt: a provider
    /// whose terms set no ceiling has nothing to be short of.
    @Test("an uncapped provider is never short of space")
    func uncappedProviderNeverAsks() async {
        let downloader = Self.downloader(.unlimited)
        let shortfall = await downloader.spaceShortfall(
            tiles: Self.tiles(100),
            source: Self.source(Self.osm)
        )
        #expect(shortfall == nil)
    }

    @Test("a download that fits under the ceiling does not ask")
    func downloadThatFitsDoesNotAsk() async {
        let downloader = Self.downloader(
            Self.broker(limit: Self.bytes(forTiles: 10), used: 0, reclaimable: Self.bytes(forTiles: 10))
        )
        let shortfall = await downloader.spaceShortfall(
            tiles: Self.tiles(4),
            source: Self.source(Self.stadia)
        )
        #expect(shortfall == nil)
    }

    /// The shortfall is what is missing, not what the download costs: three
    /// tiles' room is already free, so a five-tile plan asks for two.
    @Test("the shortfall names what is missing, and the licence it is against")
    func shortfallIsTheGap() async throws {
        let limit = Self.bytes(forTiles: 10)
        let downloader = Self.downloader(
            Self.broker(
                limit: limit,
                used: Self.bytes(forTiles: 7),
                reclaimable: Self.bytes(forTiles: 7)
            )
        )

        let shortfall = try #require(
            await downloader.spaceShortfall(
                tiles: Self.tiles(5),
                source: Self.source(Self.stadia)
            )
        )

        #expect(shortfall.bytesToFree == Self.bytes(forTiles: 2))
        #expect(shortfall.limit == limit)
        #expect(shortfall.providerName == Self.stadia.name)
    }

    /// A ceiling with nothing reclaimable under it cannot be made to fit, and
    /// asking to free space that does not exist is a dialog with no answer.
    /// The download proceeds and stops at the ceiling instead, where
    /// ``failureMessage`` explains it.
    @Test("nothing reclaimable means no question to ask")
    func nothingToReclaimDoesNotAsk() async {
        let downloader = Self.downloader(
            Self.broker(limit: Self.bytes(forTiles: 4), used: Self.bytes(forTiles: 4))
        )
        let shortfall = await downloader.spaceShortfall(
            tiles: Self.tiles(6),
            source: Self.source(Self.stadia)
        )
        #expect(shortfall == nil)
    }

    /// Freeing is bounded by what is actually reclaimable: a plan short by
    /// five tiles with two tiles' worth of other maps on disk asks for the
    /// two, and takes what it can get.
    @Test("the request is capped by what could be freed")
    func shortfallIsCappedByWhatIsReclaimable() async throws {
        let downloader = Self.downloader(
            Self.broker(
                limit: Self.bytes(forTiles: 4),
                used: Self.bytes(forTiles: 4),
                reclaimable: Self.bytes(forTiles: 2)
            )
        )

        let shortfall = try #require(
            await downloader.spaceShortfall(
                tiles: Self.tiles(9),
                source: Self.source(Self.stadia)
            )
        )
        #expect(shortfall.bytesToFree == Self.bytes(forTiles: 2))
    }

    /// Nothing is waiting on an answer until a plan has actually stopped for
    /// one, which is what lets the confirmation be driven off this one
    /// optional rather than off a phase match.
    @Test("an idle download has no pending question")
    func idleDownloaderHasNoPendingShortfall() {
        #expect(Self.downloader(.unlimited).pendingSpaceShortfall == nil)
    }

    // MARK: What a stopped download says

    /// "Try again" is the one piece of advice that cannot work for somebody
    /// who has hit a licensed ceiling, so the ceiling has to be named — along
    /// with the only thing that would help.
    @Test("a download stopped at the ceiling says so, and says whose")
    func ceilingMessageNamesTheLicence() async {
        let downloader = Self.downloader(
            Self.broker(limit: Self.bytes(forTiles: 4), used: Self.bytes(forTiles: 4))
        )

        let partial = await downloader.failureMessage(
            savedCount: 3,
            plannedCount: 9,
            source: Self.source(Self.stadia)
        )
        #expect(partial.contains(Self.stadia.name))
        #expect(partial.contains("Saved 3 of 9"))
        #expect(partial.contains("Delete another saved map"))

        let nothing = await downloader.failureMessage(
            savedCount: 0,
            plannedCount: 9,
            source: Self.source(Self.stadia)
        )
        #expect(nothing.contains("are full"))
        #expect(nothing.contains("delete another saved map"))
    }

    /// Under the ceiling, a failure is a network failure, and trying again is
    /// exactly the right advice.
    @Test("a download stopped short of the ceiling blames the connection")
    func ordinaryFailureAsksForARetry() async {
        let downloader = Self.downloader(
            Self.broker(limit: Self.bytes(forTiles: 10), used: Self.bytes(forTiles: 1))
        )

        let partial = await downloader.failureMessage(
            savedCount: 2,
            plannedCount: 9,
            source: Self.source(Self.stadia)
        )
        #expect(partial.contains("Saved 2 of 9"))
        #expect(partial.contains("Try again"))
        #expect(!partial.contains(Self.stadia.name))

        let nothing = await downloader.failureMessage(
            savedCount: 0,
            plannedCount: 9,
            source: Self.source(Self.osm)
        )
        #expect(nothing.contains("Check your connection"))
    }

    /// An uncapped provider has no ceiling to have reached, whatever the
    /// numbers say — the quota branch must not be entered for it at all.
    @Test("an uncapped provider never blames a ceiling")
    func uncappedFailureIsAlwaysOrdinary() async {
        let downloader = Self.downloader(.unlimited)
        let message = await downloader.failureMessage(
            savedCount: 0,
            plannedCount: 40,
            source: Self.source(Self.osm)
        )
        #expect(message.contains("Check your connection"))
    }
}
