//
//  OfflineDownloadResumeTests.swift
//  OpenHikesTests
//
//  What a bulk download keeps when it does not get to the end, and what a
//  second attempt then has to pay for.
//
//  `OfflineDownloadClaimTests` owns the claim a *finished* run makes. This
//  suite owns the half the old design had no answer for: a run's tiles were
//  claimed once, at the end, so a process evicted at 90% of four thousand
//  tiles kept none of them — the next launch trim deletes every durable tile
//  no hike claims — and the restart re-fetched every one against a provider
//  whose terms this app is careful about.
//
//  **A killed process cannot be induced from a suite**, so what stands in for
//  it is `cancel()`: both leave a run that never reached `finalize`, and the
//  question either way is what is in the store at that moment. The difference
//  between them is only that a cancel runs code afterwards and a kill does
//  not, and the assertion here is about what was already committed before
//  either.
//

import Foundation
@testable import OpenHikes
import SwiftData
import Testing

@Suite("A download that does not finish")
struct OfflineDownloadResumeTests {
    /// Deep enough that the plan comfortably exceeds
    /// ``OfflineTileDownloader/claimBatchSize``, which is what makes a batch
    /// fire at all. Stadia for its download policy — the one provider whose
    /// terms permit a bulk run — with a template pointing nowhere, since every
    /// save is injected.
    private static let source = ActiveTileSource(
        providerID: TileProvider.stadiaOutdoors.id,
        urlTemplate: "https://example.invalid/{z}/{x}/{y}.png",
        maximumZ: 16
    )

    /// Small enough that a fixture route's plan holds several batches. The
    /// shipped number is `OfflineTileDownloader.defaultClaimBatchSize`; what
    /// is being asserted here is the *rule*, and the rule does not depend on
    /// where the threshold sits.
    private static let batchSize = 5

    private static func downloader(
        saveTile: @escaping @Sendable (String, URL) async -> Bool
    ) -> OfflineTileDownloader {
        OfflineTileDownloader(
            isOnline: { true },
            registry: OfflineDownloadRegistry(),
            claimBatchSize: batchSize,
            saveTile: saveTile
        )
    }

    private func claim(for hike: Hike) -> OfflineTileDownloader.Claim {
        { record in try OfflineDownloadClaim.commit(record, for: hike) }
    }

    private func seedHike(in sandbox: StoreSandbox) throws -> UUID {
        try sandbox.withStore { context in
            let hike = Fixture.hike(in: context)
            try context.save()
            return hike.id
        }
    }

    private func committedCoverage(
        for id: UUID,
        in sandbox: StoreSandbox
    ) throws -> [OfflineDownloadRecord] {
        try sandbox.withStore { context in
            try context
                .fetch(FetchDescriptor<Hike>(predicate: #Predicate { $0.id == id }))
                .first?
                .offlineDownloads ?? []
        }
    }

    /// Counts the tile requests a run actually put on the wire, which is what
    /// "does not pay for them twice" means in the only terms the provider
    /// cares about.
    private actor Counter {
        private(set) var value = 0

        func increment() { value += 1 }
    }

    /// Waits for the run's first batch claim without polling.
    ///
    /// Continuation-based for the same reason
    /// ``OfflineTileDownloader/waitForPlanning()`` is: this is awaited from the
    /// main actor, which is exactly where a `Task.yield()` spin would compete
    /// with the run it is waiting for — and re-opening the store on each turn
    /// of such a loop would compete with it a great deal harder.
    @MainActor
    private final class BatchSignal {
        private var waiter: CheckedContinuation<Void, Never>?
        private(set) var claims: [OfflineDownloadRecord] = []

        func record(_ record: OfflineDownloadRecord) {
            claims.append(record)
            waiter?.resume()
            waiter = nil
        }

        /// Returns once at least one claim has been made, immediately if one
        /// already has.
        func firstClaim() async {
            await claims(atLeast: 1)
        }

        /// Returns once `count` claims have been made.
        func claims(atLeast count: Int) async {
            while claims.count < count {
                await withCheckedContinuation { continuation in waiter = continuation }
            }
        }
    }

    /// The claim a download is given, with a signal wired through it so the
    /// test can catch the run mid-flight.
    private func claim(
        for hike: Hike,
        signalling signal: BatchSignal
    ) -> OfflineTileDownloader.Claim {
        { record in
            try OfflineDownloadClaim.commit(record, for: hike)
            signal.record(record)
        }
    }

    /// Lets a fixed number of tiles land and then blocks for good, so a run
    /// can be caught in the middle rather than raced.
    private actor SavesThenStalls {
        private var attempted = 0
        private var landed = 0
        private let limit: Int
        /// **An array, not one continuation.** ``OfflineTileDownloader/
        /// inFlightWindow`` tiles are in the task group at once, so several
        /// reach the stall together — a single stored continuation would be
        /// overwritten by the next arrival and the ones it replaced would
        /// never resume, which hangs `waitForCurrentRun()` rather than failing
        /// anything.
        private var parked: [CheckedContinuation<Void, Never>] = []

        init(limit: Int) { self.limit = limit }

        func save() async -> Bool {
            attempted += 1
            guard attempted <= limit else {
                // Parked for the rest of the test. The run is cancelled out
                // from under this, which is what a suspended process looks
                // like from inside a tile fetch.
                await withCheckedContinuation { continuation in parked.append(continuation) }
                return false
            }
            landed += 1
            return true
        }

        /// The tiles that actually reached disk — **not** the number of calls.
        /// A parked save writes nothing and returns `false`, so the run is
        /// right never to claim it; counting those attempts as fetched tiles
        /// charges a stopped run for tiles it never got, and how many of them
        /// pile up is down to how the runner happened to schedule the task
        /// group.
        var savedCount: Int { landed }

        func release() {
            for continuation in parked { continuation.resume() }
            parked = []
        }
    }

    // MARK: What a run that never finished keeps

    /// **The one the issue was filed about.** Before this, the store held
    /// nothing at this moment and every tile already on disk was a trim away
    /// from being deleted.
    @Test("tiles already fetched are claimed before the run ends")
    func partialCoverageIsCommittedMidRun() async throws {
        let sandbox = try StoreSandbox()
        let id = try seedHike(in: sandbox)
        let saves = SavesThenStalls(limit: Self.batchSize * 2)
        let signal = BatchSignal()

        try await sandbox.withStore { context in
            let started = try #require(
                try context.fetch(
                    FetchDescriptor<Hike>(predicate: #Predicate { $0.id == id })
                ).first
            )
            let downloader = Self.downloader(saveTile: { _, _ in await saves.save() })
            downloader.start(
                route: started.route,
                source: Self.source,
                claim: claim(for: started, signalling: signal)
            )
            await downloader.waitForPlanning()
            #expect(
                downloader.total > Self.batchSize,
                "precondition: the plan has to be big enough for a batch to fire"
            )
            // Waits on the effect rather than on a duration: the run has got
            // far enough the moment its first batch has been committed.
            await signal.firstClaim()
            downloader.cancel()
            await saves.release()
            await downloader.waitForCurrentRun()
        }

        let claimed = try committedCoverage(for: id, in: sandbox)
        let keys = try #require(claimed.first?.savedTileKeys)
        #expect(!keys.isEmpty, "a run stopped in the middle keeps what it fetched")
        #expect(
            keys.count >= Self.batchSize,
            "at least one whole batch was committed"
        )
    }

    /// The bound on what a kill can cost. A batch is committed every
    /// `claimBatchSize` tiles, so what the run has fetched and not yet claimed
    /// is one batch short of the next commit — and a tile whose save finished
    /// while the run was still busy with an earlier result is on disk without
    /// the run having counted it at all, which is another
    /// ``OfflineTileDownloader/inFlightWindow``. Both are constants: what is
    /// being asserted is that a kill costs a fixed handful, not the whole run.
    @Test("what a stopped run loses is a fixed handful, not the run")
    func lossIsBoundedByOneBatch() async throws {
        let sandbox = try StoreSandbox()
        let id = try seedHike(in: sandbox)
        let landed = Self.batchSize * 3
        let saves = SavesThenStalls(limit: landed)
        let signal = BatchSignal()

        try await sandbox.withStore { context in
            let started = try #require(
                try context.fetch(
                    FetchDescriptor<Hike>(predicate: #Predicate { $0.id == id })
                ).first
            )
            let downloader = Self.downloader(saveTile: { _, _ in await saves.save() })
            downloader.start(
                route: started.route,
                source: Self.source,
                claim: claim(for: started, signalling: signal)
            )
            await downloader.waitForPlanning()
            // Two batches in, so the third is the one in progress when the run
            // stops — which is the window the bound is about.
            await signal.claims(atLeast: 2)
            downloader.cancel()
            await saves.release()
            await downloader.waitForCurrentRun()
        }

        let keys = try #require(try committedCoverage(for: id, in: sandbox).first?.savedTileKeys)
        let unclaimed = await saves.savedCount - keys.count
        #expect(
            unclaimed < Self.batchSize + OfflineTileDownloader.inFlightWindow,
            "what a stopped run leaves unclaimed does not grow with the run"
        )
    }

    // MARK: What the next attempt pays for

    /// The other half of the fix. Claiming what landed is worth nothing if the
    /// restart fetches it all again anyway, which is what `start(route:source:
    /// claim:)` did — it planned from the route and had no notion of a prior
    /// run.
    @Test("a resumed run fetches only the tiles that are missing")
    func aResumedRunFetchesOnlyTheGap() async throws {
        let sandbox = try StoreSandbox()
        let id = try seedHike(in: sandbox)

        let (planned, alreadySaved) = try await sandbox.withStore { context in
            let started = try #require(
                try context.fetch(
                    FetchDescriptor<Hike>(predicate: #Predicate { $0.id == id })
                ).first
            )
            let saves = SavesThenStalls(limit: Self.batchSize * 2)
            let signal = BatchSignal()
            let downloader = Self.downloader(saveTile: { _, _ in await saves.save() })
            downloader.start(
                route: started.route,
                source: Self.source,
                claim: claim(for: started, signalling: signal)
            )
            await downloader.waitForPlanning()
            let total = downloader.total
            await signal.firstClaim()
            downloader.cancel()
            await saves.release()
            await downloader.waitForCurrentRun()
            let kept = signal.claims.reduce(into: Set<String>()) { keys, record in
                keys.formUnion(record.savedTileKeys)
            }
            return (total, kept.count)
        }

        #expect(alreadySaved > 0, "precondition: the first run kept something")

        let requested = Counter()
        try await sandbox.withStore { context in
            let resumed = try #require(
                try context.fetch(
                    FetchDescriptor<Hike>(predicate: #Predicate { $0.id == id })
                ).first
            )
            let downloader = Self.downloader { _, _ in
                await requested.increment()
                return true
            }
            downloader.start(
                route: resumed.route,
                source: Self.source,
                alreadySaved: OfflineTileDownloader.resumableKeys(
                    from: resumed.offlineDownloads,
                    source: Self.source
                ),
                claim: claim(for: resumed)
            )
            await downloader.waitForPlanning()
            // The map is still the whole map, which is what the bar measures.
            #expect(downloader.total == planned)
            await downloader.waitForCurrentRun()
        }

        let fetched = await requested.value
        #expect(
            fetched == planned - alreadySaved,
            "the second run asks the tile host only for what is missing"
        )
    }

    /// And having filled the gap, the run is complete — so the partial records
    /// are replaced by the compact one that re-derives the grid, rather than
    /// the hike carrying a list of four thousand keys forever.
    @Test("a resumed run that closes the gap commits a complete record")
    func aClosedGapBecomesACompleteRecord() async throws {
        let sandbox = try StoreSandbox()
        let id = try seedHike(in: sandbox)

        try await sandbox.withStore { context in
            let started = try #require(
                try context.fetch(
                    FetchDescriptor<Hike>(predicate: #Predicate { $0.id == id })
                ).first
            )
            let saves = SavesThenStalls(limit: Self.batchSize * 2)
            let signal = BatchSignal()
            let downloader = Self.downloader(saveTile: { _, _ in await saves.save() })
            downloader.start(
                route: started.route,
                source: Self.source,
                claim: claim(for: started, signalling: signal)
            )
            await downloader.waitForPlanning()
            await signal.firstClaim()
            downloader.cancel()
            await saves.release()
            await downloader.waitForCurrentRun()
        }

        try await sandbox.withStore { context in
            let resumed = try #require(
                try context.fetch(
                    FetchDescriptor<Hike>(predicate: #Predicate { $0.id == id })
                ).first
            )
            let downloader = Self.downloader(saveTile: { _, _ in true })
            downloader.start(
                route: resumed.route,
                source: Self.source,
                alreadySaved: OfflineTileDownloader.resumableKeys(
                    from: resumed.offlineDownloads,
                    source: Self.source
                ),
                claim: claim(for: resumed)
            )
            await downloader.waitForCurrentRun()
            #expect(downloader.phase == .finished)
        }

        let claimed = try committedCoverage(for: id, in: sandbox)
        #expect(claimed.count == 1)
        #expect(
            claimed.first?.savedTileKeys.isEmpty == true,
            "a whole map is re-derived from the route rather than listed"
        )
    }

    // MARK: Which coverage counts as resumable

    /// Tiles are namespaced by provider and a shallower run saved none of the
    /// deeper levels, so neither match alone is the same download.
    @Test("only coverage from the same provider and depth is resumable")
    func resumableKeysMatchProviderAndDepth() {
        let records = [
            OfflineDownloadRecord(
                providerID: Self.source.providerID,
                maxZoom: Self.source.maximumZ,
                savedTileKeys: ["mine-1", "mine-2"]
            ),
            OfflineDownloadRecord(
                providerID: "some.other.provider",
                maxZoom: Self.source.maximumZ,
                savedTileKeys: ["theirs-1"]
            ),
            OfflineDownloadRecord(
                providerID: Self.source.providerID,
                maxZoom: Self.source.maximumZ - 2,
                savedTileKeys: ["shallower-1"]
            ),
        ]

        let resumable = OfflineTileDownloader.resumableKeys(from: records, source: Self.source)

        #expect(resumable == ["mine-1", "mine-2"])
    }

    /// A complete record lists no keys — the grid is re-derived from the route
    /// — so there is nothing here to resume *from*, and re-deriving it would be
    /// the O(tileBudget) trig work this function exists to avoid on the main
    /// actor.
    @Test("a complete record contributes no resumable keys")
    func aCompleteRecordIsNotResumedFrom() {
        let records = [
            OfflineDownloadRecord(
                providerID: Self.source.providerID,
                maxZoom: Self.source.maximumZ
            ),
        ]

        #expect(OfflineTileDownloader.resumableKeys(from: records, source: Self.source).isEmpty)
    }
}
