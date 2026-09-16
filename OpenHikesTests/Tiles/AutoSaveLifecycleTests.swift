//
//  AutoSaveLifecycleTests.swift
//  OpenHikesTests
//
//  "Auto-save lifecycle", split out of AutoSaveTileTests.swift so that a file
//  declares one @Suite. That file's header still holds the context the two
//  share.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import SwiftData
import Testing

/// The lifecycle states the two suites above don't cross: the suspension
/// `sceneWillResignActive` enters, and the deletion paths that read a
/// hike's manifest in order to free tiles by it. Each is covered on its
/// own; what isn't is what the user-facing operations do *while*
/// suspension is in effect.
///
/// That matters because suspension defers selection changes rather than
/// applying them, while every deletion path in the app is specified as
/// "flush first, then read the manifest" — and an unflushed pending set is
/// durable tiles on disk with nothing left pointing at them.
@Suite("Auto-save lifecycle")
struct AutoSaveLifecycleTests {
    private let sandbox = TileSandbox()

    /// A tile inside the ridge fixture's corridor, saved through the same path
    /// the renderer uses so the store's pending set is populated for real.
    private func persistOneTile(key: String) async throws {
        try sandbox.browse(key: key)
        await offMain {
            sandbox.store.considerPersisting(key: key, z: 14, x: 2638, y: 6357)
        }
    }

    private func tileKey(_ id: String) -> String { "osm/14/2638/6357@2.0-\(id)" }

    /// Turning the Auto-Save toggle off is how the hike sheet's Delete button
    /// folds the last drain window's tiles into the manifest before reading
    /// it — `deleteStoredTiles()` calls `setEnabled(false, for:)` first,
    /// because "reading the manifest ahead of that would delete a snapshot
    /// taken up to two seconds ago and strand everything saved since —
    /// durably, where nothing would reclaim it."
    ///
    /// While suspended, `setEnabled` takes the deferred branch and returns
    /// *without* deactivating, so that flush never happens. What saves the
    /// delete is a second mechanism entirely: `sceneWillResignActive` already
    /// folded the pending set in on its way out, and `acceptsNewClaims` is
    /// false from that moment, so there is nothing left un-flushed to strand.
    ///
    /// Two independent guarantees standing on each other is worth a test of
    /// its own: the deferred branch is only safe *because* suspension both
    /// flushes and stops claiming, and neither of those facts is stated
    /// anywhere near `setEnabled`.
    @Test("a delete during suspension still sees every tile that reached disk")
    func disablingWhileSuspendedLosesNothing() async throws {
        let context = try Fixture.modelContext()
        let controller = AutoSaveController(store: sandbox.store, drainInterval: nil)
        let hike = Fixture.hike(in: context) { $0.autoSaveTilesEnabled = true }
        controller.hikeSelectionChanged(to: hike)
        await controller.waitForActivation()

        let key = tileKey(UUID().uuidString)
        try await persistOneTile(key: key)
        #expect(sandbox.isSaved(key), "precondition: it really did reach durable storage")

        // The scene resigns active — a phone call, a swipe up, App Switcher.
        controller.sceneWillResignActive { /* scene resigned active */ }
        // …and the user taps Delete on the hike sheet, whose first act is to
        // turn auto-save off. This is the branch that does not flush.
        controller.setEnabled(false, for: hike)

        #expect(
            hike.autoSavedTileKeys.contains(key),
            "the tile is durably on disk; the manifest is the only thing that can free it"
        )

        // And nothing new can be claimed in the window either, which is the
        // other half of why the deferred branch gets away with it.
        let laterKey = tileKey(UUID().uuidString)
        try await persistOneTile(key: laterKey)
        #expect(!sandbox.isSaved(laterKey), "a suspended store must not take new claims")
    }

    /// The same window, reached the other way: deleting the hike outright.
    /// `standDown(for:)` exists precisely to flush regardless of suspension
    /// (`flushWhileSuspended: true`), so this one must hold — it's the
    /// contrast that shows the gap above is an omission rather than the
    /// intended policy.
    @Test("deleting a hike folds in what it just saved, suspended or not")
    func deletingWhileSuspendedStillFlushes() async throws {
        let context = try Fixture.modelContext()
        let controller = AutoSaveController(store: sandbox.store, drainInterval: nil)
        let hike = Fixture.hike(in: context) { $0.autoSaveTilesEnabled = true }
        controller.hikeSelectionChanged(to: hike)
        await controller.waitForActivation()

        let key = tileKey(UUID().uuidString)
        try await persistOneTile(key: key)

        controller.sceneWillResignActive { /* scene resigned active */ }
        let standDown = try #require(
            controller.standDown(for: hike),
            "the active hike's stand-down is what a refused deletion would put back"
        )

        #expect(
            hike.autoSavedTileKeys.contains(key),
            "the delete path flushes past suspension so the tiles it frees are all of them"
        )
        // Nothing for a refused deletion to hand back, and that is right:
        // `sceneWillResignActive` folded this key under a save of its own, so
        // it is committed and a rollback cannot take it away. The stand-down
        // carries only the fold that is still unsaved.
        #expect(standDown.foldedKeys.isEmpty)
    }

    /// `sceneWillResignActive` appends the pending snapshot to the manifest
    /// and rolls it back if the save throws. The rollback removes by *count*
    /// (`removeSubrange(previousCount...)`), which is only correct while
    /// nothing else has appended in between — and what guarantees that is
    /// `flushPendingKeys()`'s own `isSuspended` guard, set before the append.
    @Test("a failed suspension save leaves the manifest exactly as it found it")
    func failedSuspensionSaveRestoresTheManifest() async throws {
        let context = try Fixture.modelContext()
        let controller = AutoSaveController(store: sandbox.store, drainInterval: nil)
        let hike = Fixture.hike(in: context) { $0.autoSaveTilesEnabled = true }
        hike.autoSavedTileKeys = ["osm/14/1/1@2.0", "osm/14/1/2@2.0"]
        controller.hikeSelectionChanged(to: hike)
        await controller.waitForActivation()
        let before = hike.autoSavedTileKeys

        try await persistOneTile(key: tileKey(UUID().uuidString))

        struct SaveFailed: Error {}
        controller.sceneWillResignActive { throw SaveFailed() }

        #expect(hike.autoSavedTileKeys == before, "a failed save must not leave a half-written manifest")
    }

    /// Re-selecting the hike that is already active takes `activate`'s early
    /// return: it must neither rebuild the corridor nor replace the store's
    /// state, or the pending key saved a moment ago would be dropped or folded
    /// in twice. The app does exactly this on every selection change —
    /// `OpenHikesModel.selectedHikeDidChange` and `HikeDetailView`'s `.task`
    /// both call `hikeSelectionChanged` for one tap.
    @Test("re-selecting the same hike doesn't lose or duplicate its pending tiles")
    func reactivatingTheSameHikeIsIdempotent() async throws {
        let context = try Fixture.modelContext()
        let controller = AutoSaveController(store: sandbox.store, drainInterval: nil)
        let hike = Fixture.hike(in: context) { $0.autoSaveTilesEnabled = true }
        controller.hikeSelectionChanged(to: hike)
        await controller.waitForActivation()

        let key = tileKey(UUID().uuidString)
        try await persistOneTile(key: key)

        // The two call sites that both fire for one tap.
        controller.hikeSelectionChanged(to: hike)
        controller.hikeSelectionChanged(to: hike)
        controller.flushPendingKeys()

        #expect(hike.autoSavedTileKeys.filter { $0 == key }.count == 1, "one tile, one entry")
    }

    /// Resuming through the deferred-selection branch, for the hike that was
    /// already active. `sceneWillResignActive` leaves the store refusing new
    /// claims; `sceneDidBecomeActive` resumes it — but a selection change that
    /// arrived while suspended is replayed through `applySelection` instead,
    /// which returns early for the hike it is already on. That early return
    /// used to skip the resume as well, so auto-save spent the rest of the
    /// session declining every tile, silently, with the toggle still on.
    ///
    /// It also must not resume by re-activating: `beginActiveHike` installs an
    /// empty corridor, which rejects everything until the rebuild lands.
    @Test("returning to the foreground resumes saving for the hike already selected")
    func deferredReselectionResumesSaving() async throws {
        let context = try Fixture.modelContext()
        let controller = AutoSaveController(store: sandbox.store, drainInterval: nil)
        let hike = Fixture.hike(in: context) { $0.autoSaveTilesEnabled = true }
        controller.hikeSelectionChanged(to: hike)
        await controller.waitForActivation()

        controller.sceneWillResignActive { /* scene resigned active */ }
        // SwiftUI re-publishes the selection while the scene is inactive — the
        // same hike, so this is deferred rather than applied.
        controller.hikeSelectionChanged(to: hike)
        controller.sceneDidBecomeActive()
        await controller.waitForActivation()

        let key = tileKey(UUID().uuidString)
        try await persistOneTile(key: key)
        #expect(sandbox.isSaved(key), "auto-save must claim tiles again once the scene is active")

        controller.flushPendingKeys()
        #expect(hike.autoSavedTileKeys.contains(key))
    }
}
