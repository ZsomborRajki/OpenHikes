//
//  OfflineTileDownloaderTests+Window.swift
//  OpenHikesTests
//
//  The in-flight window is where the app decides how hard to lean on a tile
//  host. A task group bounds when work starts, not how much of it there is,
//  so `run(tiles:…)` primes the group with a window's worth and then refills
//  it one task per result. What these pin is that hand-off: every planned
//  tile asked for exactly once, never more of the route dispatched than the
//  window holds, and nothing asked for at all once the download is cancelled.
//
//  They inject their own ``TileLoadGate`` rather than using the app's. The
//  shared one is narrower than the window it would be measuring — a bulk
//  download may hold only its share of the app's blocking slots — and it is
//  shared with every other suite that loads a tile.
//

import Foundation
@testable import OpenHikes
import Testing

extension OfflineDownloadStateTests {
    /// Deep enough that the route enumerates comfortably more tiles than the
    /// window holds; otherwise "the window refilled" and "there was nothing
    /// left to add" look identical. Thunderforest for its download policy
    /// alone — the template points nowhere and every save is injected.
    private static let deepSource = ActiveTileSource(
        providerID: TileProvider.thunderforestOutdoors.id,
        urlTemplate: "https://example.invalid/{z}/{x}/{y}.png",
        maximumZ: 16
    )

    /// Wide enough to admit anything, so the downloader's own window is what
    /// binds rather than the gate.
    private static func openGate() -> TileLoadGate {
        TileLoadGate(totalBudget: 64, backgroundBudget: 64)
    }

    /// The deepest the gate's background queue got — admitted plus waiting —
    /// polled until `target` is reached or the budget runs out.
    ///
    /// A gate that admits one tile at a time turns its queue into a count of
    /// what the window has dispatched and not yet heard back about, which is
    /// otherwise invisible from outside the group. The deadline is real time
    /// because the interesting assertion is a negative one: "nothing more was
    /// dispatched" is only worth something if something waited for it.
    private static func gateDepth(
        of gate: TileLoadGate,
        reaching target: Int,
        within budget: Duration
    ) async -> Int {
        var deepest = 0
        let deadline = ContinuousClock.now + budget
        repeat {
            let state = await gate.testState
            deepest = max(deepest, state.background + state.backgroundWaiters)
            if deepest >= target { return deepest }
            await Task.yield()
        } while ContinuousClock.now < deadline
        return deepest
    }

    private static func plannedKeys() -> [String] {
        OfflineTileDownloader.tileKeys(
            for: Fixture.coordinates(Fixture.ridgeRoute),
            providerID: deepSource.providerID,
            providerMaxZoom: deepSource.maximumZ,
            maxZoom: deepSource.maximumZ,
            scale: 2
        )
    }

    /// The window refills by hand, so the two ways to get it wrong are losing
    /// the tail and asking for a tile twice — and neither shows in the phase
    /// or in the progress count, because a tile fetched twice still saves
    /// once. This compares what the transport was asked for against what
    /// planning enumerated.
    @Test("the window asks the transport for every planned tile exactly once")
    func dispatchesEveryPlannedTileOnce() async {
        let probe = SaveProbe()
        let downloader = OfflineTileDownloader(
            gate: Self.openGate(),
            isOnline: { true },
            saveTile: { key, _ in await probe.save(key) }
        )

        downloader.start(route: Fixture.ridgeRoute, source: Self.deepSource, scale: 2)
        await downloader.waitForCurrentRun()

        let planned = Self.plannedKeys()
        let requested = await probe.requestedKeys
        #expect(planned.count > OfflineTileDownloader.inFlightWindow, "precondition: more tiles than fit the window")
        #expect(requested.count == planned.count, "a tile asked for twice is a request the host didn't need to serve")
        #expect(Set(requested) == Set(planned))
        #expect(downloader.phase == .finished)
    }

    /// What the tile host is owed. With every request held open nothing can
    /// come back to free a slot, so a correct window stalls with exactly its
    /// own width dispatched — where an unbounded `addTask` loop would have
    /// queued the whole route.
    @Test("the window never dispatches more of the route than it holds")
    func neverDispatchesMoreThanTheWindow() async {
        let gate = TileLoadGate(totalBudget: 1, backgroundBudget: 1)
        let probe = SaveProbe(holdingSaves: true)
        let downloader = OfflineTileDownloader(
            gate: gate,
            isOnline: { true },
            saveTile: { key, _ in await probe.save(key) }
        )
        let window = OfflineTileDownloader.inFlightWindow

        downloader.start(route: Fixture.ridgeRoute, source: Self.deepSource, scale: 2)
        await downloader.waitForPlanning()
        await probe.waitForFirstSave()

        #expect(downloader.total > window, "precondition: the window couldn't hold the route")
        #expect(
            await Self.gateDepth(of: gate, reaching: window, within: .seconds(5)) == window,
            "the window is primed in full"
        )
        #expect(
            await Self.gateDepth(of: gate, reaching: window + 1, within: .milliseconds(500)) == window,
            "and nothing beyond it is dispatched until a tile comes back"
        )

        downloader.cancel()
        await probe.release()
        await downloader.waitForCurrentRun()
    }

    /// Cancellation reaches the tiles queued behind the gate as well as the
    /// one already fetching: a child that wakes to find its download
    /// cancelled returns without asking the host for anything. With a gate of
    /// one, everything after the first tile is queued, so a cancelled
    /// download must have asked for exactly the tile that got through.
    @Test("cancelling stops tiles queued at the load gate from being fetched")
    func cancellationReachesQueuedTiles() async {
        let probe = SaveProbe(holdingSaves: true)
        let downloader = OfflineTileDownloader(
            gate: TileLoadGate(totalBudget: 1, backgroundBudget: 1),
            isOnline: { true },
            saveTile: { key, _ in await probe.save(key) }
        )

        downloader.start(route: Fixture.ridgeRoute, source: Self.deepSource, scale: 2)
        await downloader.waitForPlanning()
        // Waited for rather than slept past: the window is only genuinely
        // pumping once a tile has reached the transport.
        await probe.waitForFirstSave()
        downloader.cancel()
        await probe.release()
        await downloader.waitForCurrentRun()

        #expect(await probe.requestedKeys.count == 1, "a cancelled download must not fetch what was still queued")
        #expect(downloader.phase == .idle)
    }
}

/// Records what the injected transport was actually asked for, and — when it
/// holds — keeps every request open so a cancellation lands while tiles are
/// genuinely in flight rather than between them.
///
/// Continuation-based rather than timed, for the reason `HeldSaves` is: a
/// sleep only makes the overlap likely, and charges every run for it.
private actor SaveProbe {
    private(set) var requestedKeys: [String] = []
    private let holdsSaves: Bool
    private var isReleased = false
    private var held: [CheckedContinuation<Void, Never>] = []
    private var firstSaveWaiters: [CheckedContinuation<Void, Never>] = []

    init(holdingSaves: Bool = false) {
        holdsSaves = holdingSaves
    }

    func save(_ key: String) async -> Bool {
        requestedKeys.append(key)
        let waiters = firstSaveWaiters
        firstSaveWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        if holdsSaves, !isReleased {
            await withCheckedContinuation { held.append($0) }
        }
        return true
    }

    func waitForFirstSave() async {
        guard requestedKeys.isEmpty else { return }
        await withCheckedContinuation { firstSaveWaiters.append($0) }
    }

    func release() {
        isReleased = true
        let resumed = held
        held.removeAll()
        for continuation in resumed { continuation.resume() }
    }
}
