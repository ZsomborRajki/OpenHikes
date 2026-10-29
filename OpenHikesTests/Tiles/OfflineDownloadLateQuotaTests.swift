//
//  OfflineDownloadLateQuotaTests.swift
//  OpenHikesTests
//
//  A run's two quota reads, answered after the hiker has cancelled it or
//  started another (#1229).
//
//  Both reads suspend: in the app they enumerate durable storage off the main
//  actor. A run that published what it learned without asking whether it was
//  still current turned the replacement's download into a failure, and
//  `OfflineDownloadRegistry` stopped seeing it as running. Its own file so that
//  a file declares one `@Suite`; the context it shares with the rest of the
//  downloader's suites is in `OfflineTileDownloaderTests.swift`'s header.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import Testing

/// Answers the quota's space read with "no ceiling", holding the reads whose
/// ordinals it was given until the test lets them go — so an answer can be
/// made to arrive after a cancel or a restart, which is the whole race.
@MainActor
private final class HeldSpaceReads {
    private let held: Set<Int>
    private var reads = 0
    private var parked: [CheckedContinuation<Void, Never>] = []
    private var parkWaiters: [CheckedContinuation<Void, Never>] = []

    init(holding held: Set<Int>) {
        self.held = held
    }

    var broker: OfflineTileDownloader.QuotaBroker {
        .init(
            space: { [self] _ in await read() },
            reclaimable: { _, _ in 0 },
            reclaim: { _, _, _ in 0 }
        )
    }

    private func read() async -> (limit: Int64, used: Int64)? {
        reads += 1
        if held.contains(reads) {
            let waiters = parkWaiters
            parkWaiters.removeAll()
            await withCheckedContinuation { continuation in
                parked.append(continuation)
                for waiter in waiters { waiter.resume() }
            }
        }
        return nil
    }

    func waitUntilParked() async {
        guard parked.isEmpty else { return }
        await withCheckedContinuation { parkWaiters.append($0) }
    }

    func release() {
        let resumed = parked
        parked.removeAll()
        for continuation in resumed { continuation.resume() }
    }
}

/// What each save answers, switched by the test between runs: the run that
/// gets superseded fails every tile so that it reaches the failure message,
/// and its replacement either finishes or is held mid-download.
@MainActor
private final class ScriptedSaves {
    enum Outcome {
        case fail
        case succeed
        /// Lets the first `count` saves through, then parks the rest.
        case holdAfter(Int)
    }

    var outcome = Outcome.fail
    private var passed = 0
    private var parked: [CheckedContinuation<Void, Never>] = []
    private var parkWaiters: [CheckedContinuation<Void, Never>] = []

    func save() async -> Bool {
        switch outcome {
        case .fail:
            return false
        case .succeed:
            return true
        case .holdAfter(let count):
            guard passed >= count else {
                passed += 1
                return true
            }
            let waiters = parkWaiters
            parkWaiters.removeAll()
            await withCheckedContinuation { continuation in
                parked.append(continuation)
                for waiter in waiters { waiter.resume() }
            }
            return true
        }
    }

    func waitUntilParked() async {
        guard parked.isEmpty else { return }
        await withCheckedContinuation { parkWaiters.append($0) }
    }

    func release() {
        outcome = .succeed
        let resumed = parked
        parked.removeAll()
        for continuation in resumed { continuation.resume() }
    }
}

/// Every key a run's batches claimed, in order.
@MainActor
private final class ClaimLog {
    private(set) var keys: [String] = []

    var claim: OfflineTileDownloader.Claim {
        { [self] record in keys += record.savedTileKeys }
    }
}

/// Every wait here is on a continuation a run resumes, so a run that never
/// gets there would wait forever; the limit turns that into a failure.
@MainActor
@Suite("A superseded download's late quota answers", .timeLimit(.minutes(1)))
struct OfflineDownloadLateQuotaTests {
    /// Points nowhere, so nothing is fetched. Borrowed from
    /// `OfflineDownloadStateTests` for the reason that suite gives: only the
    /// id's *policy* matters, since every save is injected. Two zoom levels
    /// deep, so a replacement held after its first tile still has more to
    /// fetch.
    private let source = ActiveTileSource(
        providerID: TileProvider.stadiaOutdoors.id,
        urlTemplate: "http://127.0.0.1:9/{z}/{x}/{y}.png",
        maximumZ: 12
    )

    private func downloader(
        reads: HeldSpaceReads,
        saves: ScriptedSaves,
        registry: OfflineDownloadRegistry = OfflineDownloadRegistry(),
        claimBatchSize: Int = OfflineTileDownloader.defaultClaimBatchSize
    ) -> OfflineTileDownloader {
        OfflineTileDownloader(
            // Wide enough that a superseded run's children never queue behind
            // a replacement's held saves: without the fix, the stale run
            // enters `run` and has to drain rather than hang.
            gate: TileLoadGate(totalBudget: 16, backgroundBudget: 16),
            isOnline: { true },
            quota: reads.broker,
            registry: registry,
            backgroundTime: .unavailable,
            claimBatchSize: claimBatchSize,
            saveTile: { _, _ in await saves.save() }
        )
    }

    /// Starts a run whose every tile fails, and returns it parked on the
    /// failure message's quota read — its second, after the shortfall check.
    private func runParkedOnItsFailureMessage(
        _ downloader: OfflineTileDownloader,
        reads: HeldSpaceReads
    ) async throws -> Task<Void, Never> {
        downloader.start(route: Fixture.ridgeRoute, source: source, claim: Fixture.unrecordedClaim)
        let run = try #require(downloader.lastRun)
        await reads.waitUntilParked()
        #expect(downloader.phase == .downloading, "precondition: the failure is not published yet")
        return run
    }

    @Test("a cancel during the failure message's quota read stays a cancel")
    func cancelOutlastsTheFailure() async throws {
        let reads = HeldSpaceReads(holding: [2])
        let saves = ScriptedSaves()
        let downloader = downloader(reads: reads, saves: saves)
        let abandoned = try await runParkedOnItsFailureMessage(downloader, reads: reads)

        downloader.cancel()
        reads.release()
        await abandoned.value

        #expect(downloader.phase == .idle)
        #expect(downloader.total == 0)
    }

    @Test("a replacement still downloading keeps its phase over the old run's failure")
    func replacementKeepsDownloading() async throws {
        let reads = HeldSpaceReads(holding: [2])
        let saves = ScriptedSaves()
        let registry = OfflineDownloadRegistry()
        let downloader = downloader(reads: reads, saves: saves, registry: registry)
        let abandoned = try await runParkedOnItsFailureMessage(downloader, reads: reads)

        downloader.cancel()
        saves.outcome = .holdAfter(1)
        downloader.start(route: Fixture.ridgeRoute, source: source, claim: Fixture.unrecordedClaim)
        await downloader.waitForPlanning()
        try #require(downloader.total > 1, "precondition: the replacement has more to fetch")
        await saves.waitUntilParked()
        await settleDelegateHop(until: "the replacement counts the tile it let through") {
            downloader.completed == 1
        }
        let total = downloader.total

        reads.release()
        await abandoned.value

        #expect(downloader.phase == .downloading)
        #expect(downloader.isRunning)
        #expect(downloader.total == total)
        #expect(downloader.completed == 1)
        // Last, because standing down is a cancel: the replacement is still
        // one the registry sees as in flight.
        #expect(registry.standDown() == 1)
        saves.release()
        await downloader.waitForCurrentRun()
    }

    @Test("a replacement that finished keeps its result over the old run's failure")
    func replacementKeepsItsResult() async throws {
        let reads = HeldSpaceReads(holding: [2])
        let saves = ScriptedSaves()
        let downloader = downloader(reads: reads, saves: saves)
        let abandoned = try await runParkedOnItsFailureMessage(downloader, reads: reads)

        downloader.cancel()
        saves.outcome = .succeed
        downloader.start(route: Fixture.ridgeRoute, source: source, claim: Fixture.unrecordedClaim)
        await downloader.waitForCurrentRun()
        #expect(downloader.phase == .finished, "precondition: the replacement finished")
        let record = downloader.completedRecord

        reads.release()
        await abandoned.value

        #expect(downloader.phase == .finished)
        #expect(downloader.completed == downloader.total)
        #expect(downloader.completedRecord == record)
    }

    /// The other suspension the issue named: a run cancelled during its
    /// shortfall check, answered "it fits", went on into `run`, which cleared
    /// the replacement's record of what it had already claimed — so the
    /// replacement's next batch claimed those keys a second time.
    @Test("a run cancelled during its shortfall check leaves the replacement's claims alone")
    func staleShortfallLeavesClaimsAlone() async throws {
        let reads = HeldSpaceReads(holding: [1])
        let saves = ScriptedSaves()
        saves.outcome = .holdAfter(1)
        let claims = ClaimLog()
        let downloader = downloader(reads: reads, saves: saves, claimBatchSize: 1)

        downloader.start(route: Fixture.ridgeRoute, source: source, claim: Fixture.unrecordedClaim)
        let abandoned = try #require(downloader.lastRun)
        await reads.waitUntilParked()
        downloader.cancel()
        downloader.start(route: Fixture.ridgeRoute, source: source, claim: claims.claim)
        await downloader.waitForPlanning()
        try #require(downloader.total > 1, "precondition: the replacement has more to fetch")
        await saves.waitUntilParked()
        await settleDelegateHop(until: "the replacement claims its first tile") { claims.keys.count == 1 }

        reads.release()
        await abandoned.value
        saves.release()
        await downloader.waitForCurrentRun()

        #expect(downloader.phase == .finished)
        #expect(claims.keys.count > 1, "precondition: the replacement claimed after the stale answer")
        #expect(claims.keys.count == Set(claims.keys).count, "no tile is claimed twice")
    }
}
