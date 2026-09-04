//
//  OfflineDownloadClaimTests.swift
//  OpenHikesTests
//
//  Who owns the tiles a bulk download wrote, and when that ownership becomes
//  true on disk rather than in a screen.
//
//  `OfflineTileDownloaderTests` owns the state machine — what a run reports
//  and what it counts. This suite owns the half that costs a walker something
//  when it is wrong: a download writes straight to durable storage, and
//  `TileCache.trimCache(claimedBy:)` deletes every durable tile no hike
//  claims, so coverage that reached disk without a committed record is a map
//  the next launch removes after the connection, battery and storage were
//  already spent on it.
//
//  Ownership used to live in `HikeDetailView`'s `onChange`, which made the
//  screen the only consumer of a record the download published — and
//  dismissing that screen cancels nothing. So what is checked here is a
//  lifetime rather than a merge: a run whose screen is gone still claims, a
//  partial run claims exactly what it verified, and a commit the store
//  refused is never reported as a saved map and never lands at a later save.
//

import Foundation
@testable import OpenHikes
import SwiftData
import Testing

@Suite("Offline download ownership")
struct OfflineDownloadClaimTests {
    /// Stadia for its download policy alone — the one source whose terms
    /// permit a bulk download — with a template that points nowhere, since
    /// every save is injected.
    private static let source = ActiveTileSource(
        providerID: TileProvider.stadiaOutdoors.id,
        urlTemplate: "https://example.invalid/{z}/{x}/{y}.png",
        maximumZ: 12
    )

    /// A directory of this test's own, for the two store files.
    private func makeSandbox() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(
                path: "offlineclaim-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    /// A container over this sandbox's own files. Deliberately not in-memory:
    /// what is being asked is what a relaunch would find, and the record lives
    /// in the *second* store — the unmirrored one ``HikeLocalState`` is in.
    private func openStore(in sandbox: URL) throws -> ModelContext {
        ModelContext(
            try ModelContainer.openHikes(
                url: sandbox.appending(path: "OpenHikes.store"),
                localURL: sandbox.appending(path: "OpenHikesLocal.store")
            )
        )
    }

    /// The claim ``HikeDetailView`` hands a download, restated so a suite can
    /// refuse the commit. Spelled as a returned closure rather than inline at
    /// each call, which is also how the view builds it — see
    /// ``HikeDetailView/offlineDownloadClaim``.
    private func claim(
        for hike: Hike,
        save: @escaping (ModelContext) throws -> Void = { try $0.save() }
    ) -> OfflineTileDownloader.Claim {
        { record in try OfflineDownloadClaim.commit(record, for: hike, save: save) }
    }

    private func hike(_ id: UUID, in sandbox: URL) throws -> Hike? {
        try openStore(in: sandbox)
            .fetch(FetchDescriptor<Hike>(predicate: #Predicate { $0.id == id }))
            .first
    }

    // MARK: A download that outlives its screen

    /// The regression. The download is started, the screen it was started
    /// from is destroyed — here, everything that would observe the run goes
    /// out of scope with it — and the tiles keep landing on durable storage
    /// regardless. Nothing is left to merge `completedRecord`, so the run
    /// itself has to be what claims, and it has to have committed before the
    /// container that could answer from memory is gone.
    @Test("a finished download is committed with nothing left observing it")
    func coverageSurvivesTheScreenThatStartedIt() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let id: UUID
        do {
            let context = try openStore(in: sandbox)
            let started = Fixture.hike(in: context)
            id = started.id
            try context.save()

            let downloader = OfflineTileDownloader(
                isOnline: { true },
                saveTile: { _, _ in true }
            )
            downloader.start(
                route: started.route,
                source: Self.source,
                claim: claim(for: started),
            )
            // Deliberately no save from the suite afterwards: one here would
            // be the test committing on the download's behalf, which is
            // precisely the autosave the old `onChange` was relying on.
            await downloader.waitForCurrentRun()
        }

        let reopened = try #require(try hike(id, in: sandbox))
        let claimed = try #require(reopened.offlineDownloads.first)
        #expect(reopened.offlineDownloads.count == 1)
        #expect(claimed.providerID == TileProvider.stadiaOutdoors.id)
        #expect(claimed.maxZoom == Self.source.maximumZ)
        #expect(
            claimed.savedTileKeys.isEmpty,
            "a complete run's coverage is re-derived from the route, not listed"
        )
    }

    /// A partial run has the same problem and one extra constraint: the record
    /// it commits is the only description of coverage that exists, so it has
    /// to carry exactly the keys the run verified rather than the whole plan.
    @Test("a partial download commits exactly the tiles that reached disk")
    func partialCoverageIsCommitted() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let id: UUID
        let verified: [String]
        do {
            let context = try openStore(in: sandbox)
            let started = Fixture.hike(in: context)
            id = started.id
            try context.save()

            let saves = AlternatingSaves()
            let downloader = OfflineTileDownloader(
                isOnline: { true },
                saveTile: { _, _ in await saves.succeedAlternating() }
            )
            downloader.start(
                route: started.route,
                source: Self.source,
                claim: claim(for: started),
            )
            await downloader.waitForCurrentRun()

            #expect(downloader.isFailed, "precondition: half the tiles is not a finished download")
            verified = try #require(downloader.completedRecord?.savedTileKeys)
            #expect(!verified.isEmpty, "precondition: some tiles did reach disk")
        }

        let reopened = try #require(try hike(id, in: sandbox))
        #expect(reopened.offlineDownloads.first?.savedTileKeys == verified)
    }

    // MARK: A store that says no

    /// The other half of making the commit the download's own: it can fail,
    /// and a failure has to reach the walker as one. "Saved for offline use"
    /// over a refused commit is a map the storage row will not show, the
    /// delete button cannot free, and the next launch trim removes.
    @Test("a refused commit is not reported as a saved map")
    func refusedCommitIsNotReportedAsSaved() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let id: UUID
        do {
            let context = try openStore(in: sandbox)
            let started = Fixture.hike(in: context)
            id = started.id
            try context.save()

            let downloader = OfflineTileDownloader(
                isOnline: { true },
                saveTile: { _, _ in true }
            )
            downloader.start(
                route: started.route,
                source: Self.source,
                claim: claim(for: started) { _ in throw CocoaError(.fileWriteUnknown) },
            )
            await downloader.waitForCurrentRun()

            #expect(downloader.isFailed)
            #expect(downloader.phase != .finished, "a map that was not recorded is not a saved map")
            // The quiet second chance the rollback exists to close: the app
            // saves this context on every autosave tick, and again when the
            // scene leaves the foreground.
            try context.save()
        }

        let reopened = try #require(try hike(id, in: sandbox))
        #expect(
            reopened.offlineDownloads.isEmpty,
            "a claim the walker was told failed must not land at the next save"
        )
    }

    /// The hike can also leave while its tiles are being fetched — a deletion
    /// from the list pops the detail screen and cancels nothing. A passthrough
    /// write to a detached ``Hike`` is a silent no-op, so the claim has to
    /// notice rather than report a manifest it never touched.
    @Test("a hike deleted mid-download is reported rather than quietly skipped")
    func aDeletedHikeIsReported() throws {
        let context = try Fixture.modelContext()
        let deleted = Fixture.hike(in: context)
        try context.save()
        context.delete(deleted)
        try context.save()

        #expect(throws: OfflineDownloadClaim.Failure.hikeIsGone) {
            try OfflineDownloadClaim.commit(
                OfflineDownloadRecord(providerID: "test", maxZoom: 12),
                for: deleted
            )
        }
    }
}

/// Every other tile saved: the shape of a download that partly landed, with
/// no timing in it.
private actor AlternatingSaves {
    private var attempts = 0

    func succeedAlternating() -> Bool {
        attempts += 1
        return !attempts.isMultiple(of: 2)
    }
}
