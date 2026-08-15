//
//  AutoSaveDrainTests.swift
//  OpenHikesTests
//
//  How a durably-saved tile gets from `AutoSaveTileStore`'s pending set into
//  the hike's SwiftData manifest.
//
//  The controller used to poll for that every two seconds, for as long as the
//  app was frontmost, whether or not a hike was even selected — one wake-up
//  every two seconds, almost always with nothing to do. It now waits
//  on `pendingKeySignals()` and sleeps only once it has been told there is
//  something to fold, so the two halves worth pinning are that a claim really
//  does raise the signal, and that work nobody claimed really doesn't.
//
//  Its own sandbox rather than the app's singletons, like every other tile
//  suite here: one `TileCache` pair and one active hike per test.
//

import Foundation
@testable import OpenHikes
import SwiftData
import Synchronization
import Testing

@Suite("Auto-save drain")
struct AutoSaveDrainTests {
    private let sandbox = TileSandbox()

    /// The ridge fixture's own tile, saved through the path the renderer uses,
    /// so the store's pending set is populated exactly as it is in the app.
    private func persistTile(key: String) async throws {
        try sandbox.browse(key: key)
        await offMain {
            sandbox.store.considerPersisting(key: key, z: 14, x: 2638, y: 6357)
        }
    }

    /// Somewhere else entirely — well outside the corridor the fixture builds,
    /// so the store declines to claim it.
    private func persistDistantTile(key: String) async throws {
        try sandbox.browse(key: key)
        await offMain {
            sandbox.store.considerPersisting(key: key, z: 14, x: 1, y: 1)
        }
    }

    private func tileKey(_ id: String) -> String { "osm/14/2638/6357@2.0-\(id)" }

    private func activeHike(in context: ModelContext) async -> (Hike, AutoSaveController) {
        let hike = Fixture.hike(in: context) { $0.autoSaveTilesEnabled = true }
        let controller = AutoSaveController(store: sandbox.store, drainInterval: nil)
        controller.hikeSelectionChanged(to: hike)
        await controller.waitForActivation()
        return (hike, controller)
    }

    /// The signal itself. Awaiting the iterator is the whole assertion: with a
    /// polling drain there is nothing to await, and a claim that raised
    /// nothing would never be delivered — hence the time limit, so a
    /// regression here reports a failure instead of wedging the run.
    @Test("a claimed tile wakes a waiting drain", .timeLimit(.minutes(1)))
    func claimingATileRaisesTheSignal() async throws {
        let context = try Fixture.modelContext()
        let (_, controller) = await activeHike(in: context)
        var signals = sandbox.store.pendingKeySignals().makeAsyncIterator()

        let key = tileKey(UUID().uuidString)
        try await persistTile(key: key)
        #expect(sandbox.isSaved(key), "precondition: the bytes really did reach durable storage")

        await signals.next()
        controller.flushPendingKeys()
    }

    /// And the half that is the point of the change: browsing that saves
    /// nothing wakes nobody. A tile outside the hike's corridor is declined
    /// before it is ever claimed, so there is nothing to fold and no reason to
    /// run.
    ///
    /// The observer records that it was woken rather than the test awaiting
    /// it, because "this never happens" can't be awaited. A run of yields is
    /// enough for a signal that was going to be delivered to arrive — and if
    /// one slips past the window the second half still fails, since it asserts
    /// on the count rather than merely on being woken at all.
    @Test("a tile the hike doesn't claim wakes nobody")
    func decliningATileRaisesNoSignal() async throws {
        let context = try Fixture.modelContext()
        let (_, controller) = await activeHike(in: context)

        let wakeups = Mutex(0)
        let signals = sandbox.store.pendingKeySignals()
        let observer = Task {
            for await _ in signals {
                wakeups.withLock { count in count += 1 }
            }
        }
        defer { observer.cancel() }

        try await persistDistantTile(key: tileKey(UUID().uuidString))
        for _ in 0..<100 { await Task.yield() }
        #expect(
            wakeups.withLock { count in count } == 0,
            "a tile nothing claims must not cost a wake-up"
        )

        // …and the observer is genuinely still listening, so the silence above
        // is the store's doing rather than a stream that was never connected.
        let claimed = tileKey(UUID().uuidString)
        try await persistTile(key: claimed)
        for _ in 0..<100 where wakeups.withLock({ count in count }) == 0 {
            await Task.yield()
        }
        #expect(wakeups.withLock { count in count } == 1)
        controller.flushPendingKeys()
    }

    /// End to end through a real drain: nothing in the test flushes, and the
    /// tile still reaches the manifest. This is what the app depends on — the
    /// manifest is the only thing that can ever free a durable tile.
    @Test("a saved tile reaches the manifest with nobody asking it to")
    func theDrainFoldsWithoutBeingAsked() async throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context) { $0.autoSaveTilesEnabled = true }
        let controller = AutoSaveController(
            store: sandbox.store,
            drainInterval: .zero
        )
        controller.hikeSelectionChanged(to: hike)
        await controller.waitForActivation()

        let key = tileKey(UUID().uuidString)
        try await persistTile(key: key)

        for _ in 0..<200 where !hike.autoSavedTileKeys.contains(key) {
            await Task.yield()
        }
        #expect(
            hike.autoSavedTileKeys.contains(key),
            "the drain has to fold a claimed tile in on its own"
        )
    }

    /// Returning to the foreground has to fold in whatever the suspension
    /// couldn't acknowledge. Nothing signals while the scene is inactive and a
    /// flush is a no-op there, so without this the keys would sit pending
    /// until the next tile happened to be drawn — and if the user never moved
    /// the map again, until the process ended.
    @Test("returning to the foreground folds in what suspension left pending")
    func resumingFlushesWhatSuspensionCouldNotAcknowledge() async throws {
        let context = try Fixture.modelContext()
        let (hike, controller) = await activeHike(in: context)

        struct SaveFailed: Error {}
        let key = tileKey(UUID().uuidString)
        try await persistTile(key: key)
        // The save fails, so the manifest is rolled back and the keys stay
        // pending — exactly the state that used to need a tile to be drawn.
        controller.sceneWillResignActive { throw SaveFailed() }
        #expect(!hike.autoSavedTileKeys.contains(key), "precondition: the rollback really did take it back out")

        controller.sceneDidBecomeActive()

        #expect(
            hike.autoSavedTileKeys.contains(key),
            "the tile is durably on disk; nothing but the manifest can free it"
        )
    }
}
