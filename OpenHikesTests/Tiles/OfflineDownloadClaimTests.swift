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
//  partial run claims exactly what it verified, a commit the store refused is
//  never reported as a saved map, and a run the walker has overtaken with a
//  deletion is stood down rather than allowed to put the coverage back.
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

    /// A hike in a store on disk, and the id to find it by again.
    private func seedHike(in sandbox: StoreSandbox) throws -> UUID {
        try sandbox.withStore { context in
            let hike = Fixture.hike(in: context)
            try context.save()
            return hike.id
        }
    }

    /// What a relaunch would find in this hike's manifest.
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

    // MARK: A download that outlives its screen

    /// The regression. The download is started, the screen it was started
    /// from is destroyed — here, everything that would observe the run goes
    /// out of scope with it — and the tiles keep landing on durable storage
    /// regardless. Nothing is left to merge `completedRecord`, so the run
    /// itself has to be what claims, and it has to have committed before the
    /// container that could answer from memory is gone.
    @Test("a finished download is committed with nothing left observing it")
    func coverageSurvivesTheScreenThatStartedIt() async throws {
        let sandbox = try StoreSandbox()
        let id = try seedHike(in: sandbox)

        try await sandbox.withStore { context in
            let started = try #require(
                try context.fetch(
                    FetchDescriptor<Hike>(predicate: #Predicate { $0.id == id })
                ).first
            )
            let downloader = OfflineTileDownloader(
                isOnline: { true },
                registry: OfflineDownloadRegistry(),
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

        let claimed = try committedCoverage(for: id, in: sandbox)
        #expect(claimed.count == 1)
        #expect(claimed.first?.providerID == TileProvider.stadiaOutdoors.id)
        #expect(claimed.first?.maxZoom == Self.source.maximumZ)
        #expect(
            claimed.first?.savedTileKeys.isEmpty == true,
            "a complete run's coverage is re-derived from the route, not listed"
        )
    }

    /// A partial run has the same problem and one extra constraint: the record
    /// it commits is the only description of coverage that exists, so it has
    /// to carry exactly the keys the run verified rather than the whole plan.
    @Test("a partial download commits exactly the tiles that reached disk")
    func partialCoverageIsCommitted() async throws {
        let sandbox = try StoreSandbox()
        let id = try seedHike(in: sandbox)

        let verified: [String] = try await sandbox.withStore { context in
            let started = try #require(
                try context.fetch(
                    FetchDescriptor<Hike>(predicate: #Predicate { $0.id == id })
                ).first
            )
            let saves = AlternatingSaves()
            let downloader = OfflineTileDownloader(
                isOnline: { true },
                registry: OfflineDownloadRegistry(),
                saveTile: { _, _ in await saves.succeedAlternating() }
            )
            downloader.start(
                route: started.route,
                source: Self.source,
                claim: claim(for: started),
            )
            await downloader.waitForCurrentRun()

            #expect(downloader.isFailed, "precondition: half the tiles is not a finished download")
            let keys = try #require(downloader.completedRecord?.savedTileKeys)
            #expect(!keys.isEmpty, "precondition: some tiles did reach disk")
            return keys
        }

        #expect(try committedCoverage(for: id, in: sandbox).first?.savedTileKeys == verified)
    }

    /// Coverage already on this device is the thing a second download must not
    /// cost the walker. ``Hike/offlineDownloads`` reads through a sidecar
    /// lookup that answers "nothing stored" when it fails, and writing through
    /// that answer inserts a *second* sidecar row: the real one is then
    /// unreachable behind a `fetchLimit` of one, and everything it claims is a
    /// trim away from deletion. The lookup cannot be made to fail from a test —
    /// `SettingsStorageFailureTests` says why — so what is pinned here is the
    /// observable half: one row per hike, holding both downloads.
    @Test("a second download joins the hike's existing sidecar rather than replacing it")
    func commitJoinsTheExistingSidecar() throws {
        let sandbox = try StoreSandbox()
        let id = try sandbox.withStore { context in
            let hike = Fixture.hike(in: context)
            hike.mergeOfflineDownload(
                OfflineDownloadRecord(providerID: "stadia_outdoors", maxZoom: 10)
            )
            try context.save()
            return hike.id
        }

        try sandbox.withStore { context in
            let hike = try #require(
                try context.fetch(
                    FetchDescriptor<Hike>(predicate: #Predicate { $0.id == id })
                ).first
            )
            try OfflineDownloadClaim.commit(
                OfflineDownloadRecord(providerID: "stadia_outdoors", maxZoom: 12),
                for: hike
            )
        }

        let claimed = try committedCoverage(for: id, in: sandbox)
        #expect(
            Set(claimed.map(\.maxZoom)) == [10, 12],
            "the earlier download must still be claimed after the later one commits"
        )
        let rows = try sandbox.withStore { context in
            try context.fetch(
                FetchDescriptor<HikeLocalState>(predicate: #Predicate { $0.hikeID == id })
            ).count
        }
        #expect(rows == 1, "a second sidecar row would hide the first one's claims from every read")
    }

    // MARK: A store that says no

    /// The other half of making the commit the download's own: it can fail,
    /// and a failure has to reach the walker as one. "Saved for offline use"
    /// over a refused commit is a map the storage row will not show, the
    /// delete button cannot free, and the next launch trim removes.
    @Test("a refused commit is not reported as a saved map")
    func refusedCommitIsNotReportedAsSaved() async throws {
        let sandbox = try StoreSandbox()
        let id = try seedHike(in: sandbox)

        try await sandbox.withStore { context in
            let started = try #require(
                try context.fetch(
                    FetchDescriptor<Hike>(predicate: #Predicate { $0.id == id })
                ).first
            )
            let downloader = OfflineTileDownloader(
                isOnline: { true },
                registry: OfflineDownloadRegistry(),
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

        #expect(
            try committedCoverage(for: id, in: sandbox).isEmpty,
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

    // MARK: A walker who deletes while it runs

    /// Surviving the screen means the walker can reach Settings while tiles
    /// are still landing, and both buttons there take the manifests and the
    /// durable directory as they find them. An in-flight run is invisible to
    /// both — its tiles are not claimed yet — so left alone it would have its
    /// tiles deleted and then claim them back, leaving the hike reporting a
    /// saved map that is largely gone. ``OfflineDownloadRegistry`` is what
    /// stands it down first.
    @Test(
        "a storage deletion stands an in-flight download down instead of racing its claim",
        arguments: [StorageDeletion.deleteAllTiles, .clearMapCache]
    )
    func aStorageDeletionStandsDownTheRun(_ deletion: StorageDeletion) async throws {
        let sandbox = try StoreSandbox()
        let tiles = TileSandbox()
        let id = try seedHike(in: sandbox)

        try await sandbox.withStore { context in
            let started = try #require(
                try context.fetch(
                    FetchDescriptor<Hike>(predicate: #Predicate { $0.id == id })
                ).first
            )
            let registry = OfflineDownloadRegistry()
            let held = HeldSaves()
            let downloader = OfflineTileDownloader(
                isOnline: { true },
                registry: registry,
                saveTile: { _, _ in await held.save() }
            )
            downloader.start(
                route: started.route,
                source: Self.source,
                claim: claim(for: started),
            )
            await downloader.waitForPlanning()
            try #require(downloader.isRunning, "precondition: the run is in flight")

            let sweep = deletion.run(in: tiles.cache, downloads: registry) { [started] }
            #expect(downloader.phase == .idle, "the deletion stands the run down before it deletes")
            await sweep?.value

            // Only now do the tiles this run had in flight come back — the
            // window in which the old code committed a record for coverage
            // the walker had just deleted.
            await held.release()
            await downloader.waitForCurrentRun()
            #expect(downloader.phase == .idle, "a stood-down run reports nothing of its own")
        }

        #expect(
            try committedCoverage(for: id, in: sandbox).isEmpty,
            "a deletion the walker asked for must not be undone by the run it interrupted"
        )
    }

    /// Which of the two Settings buttons is being asked, as something a
    /// parameterised test can carry.
    enum StorageDeletion: Sendable {
        case clearMapCache
        case deleteAllTiles

        @MainActor
        func run(
            in cache: TileCache,
            downloads: OfflineDownloadRegistry,
            fetchingHikes fetch: () throws -> [Hike]
        ) -> Task<Void, Never>? {
            switch self {
            case .clearMapCache:
                OfflineStorageActions.clearMapCache(
                    in: cache,
                    downloads: downloads,
                    fetchingHikes: fetch
                )
            case .deleteAllTiles:
                OfflineStorageActions.deleteAllTiles(
                    in: cache,
                    downloads: downloads,
                    fetchingHikes: fetch
                )
            }
        }
    }
}

/// A directory of this suite's own, holding the two store files, with every
/// container scoped to the call that opens it.
///
/// Deliberately not in-memory: what these tests ask is what a relaunch would
/// find, and the record lives in the *second* store — the unmirrored one
/// ``HikeLocalState`` is in.
///
/// Both halves of that are about the same hazard. SwiftData keeps the SQLite
/// files open for as long as its container lives, and closing one is not
/// something a test can wait for: unlinking the files a moment too early has
/// libsqlite3 log `vnode unlinked while in use` for the store, its WAL and its
/// SHM, which is noise at best and a flaky suite under parallel execution at
/// worst. A `defer` cannot close that window either — a deferred block runs
/// while the test's own locals, and the contexts behind them, are still alive.
///
/// So each store is scoped to the call that opens it, and the files are never
/// removed *during* a run. They are cleared once, when the first sandbox of a
/// run is made, which is the one moment the answer is knowable: whatever held
/// them belonged to a process that has since gone. It also leaves a failed
/// test's store on disk to look at.
private final class StoreSandbox {
    /// The parent every sandbox lives in, emptied on first use per run.
    private static let root: URL = {
        let parent = FileManager.default.temporaryDirectory
            .appending(path: "offlineclaim", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: parent)
        return parent
    }()

    let directory: URL

    init() throws {
        directory = Self.root.appending(
            path: UUID().uuidString,
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
    }

    /// Opens the stores, hands `body` a context, and lets the container go
    /// again before returning. Whatever `body` needs afterwards it has to
    /// return as a value: a `Hike` handed out here would outlive its store.
    @MainActor
    func withStore<Result>(_ body: (ModelContext) async throws -> Result) async throws -> Result {
        let context = ModelContext(
            try ModelContainer.openHikes(
                url: directory.appending(path: "OpenHikes.store"),
                localURL: directory.appending(path: "OpenHikesLocal.store")
            )
        )
        return try await body(context)
    }

    /// The synchronous half, inside an `autoreleasepool` so the container is
    /// really gone when this returns: SwiftData hands back autoreleased
    /// objects, and a pool that drains at some later point of the runtime's
    /// choosing is a store still holding its files open at the moment the
    /// directory is removed.
    @MainActor
    func withStore<Result>(_ body: (ModelContext) throws -> Result) throws -> Result {
        try autoreleasepool {
            let context = ModelContext(
                try ModelContainer.openHikes(
                    url: directory.appending(path: "OpenHikes.store"),
                    localURL: directory.appending(path: "OpenHikesLocal.store")
                )
            )
            return try body(context)
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

/// Holds every stubbed save open until the test lets it go, so a run is
/// genuinely still in flight when the deletion lands.
private actor HeldSaves {
    private var isReleased = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func save() async -> Bool {
        if !isReleased {
            await withCheckedContinuation { waiting.append($0) }
        }
        return true
    }

    func release() {
        isReleased = true
        let resumed = waiting
        waiting.removeAll()
        for continuation in resumed { continuation.resume() }
    }
}
