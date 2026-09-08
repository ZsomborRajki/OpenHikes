//
//  AutoSaveTaskLifecycleTests.swift
//  OpenHikesTests
//
//  What happens to ``AutoSaveController``'s two tasks when the controller
//  itself goes away.
//
//  The controller used to keep both of them in `nonisolated(unsafe)` storage
//  purely so a `nonisolated deinit` could reach them. They are ordinary
//  main-actor-isolated properties now, cancelled from an `isolated deinit` —
//  and SE-0371 is explicit that a final release taken off the actor
//  *schedules* that deinit rather than running it, so the two things the
//  controller actually promises are pinned here rather than assumed from the
//  cancellation being prompt: a drain that ends, and an activation that cannot
//  publish a corridor for a controller nobody holds any more.
//
//  Both are read through an effect — the store's own observer bookkeeping, and
//  a tile the corridor would have claimed — never through a sleep.
//

import Foundation
@testable import OpenHikes
import SwiftData
import Testing

@Suite("Auto-save task lifecycle")
struct AutoSaveTaskLifecycleTests {
    private let sandbox = TileSandbox()

    /// In the corridor the fixture route builds, so whether the store claims
    /// it is exactly the question "did a prepared corridor ever land?".
    private func tileKey() -> String { "osm/14/2638/6357@2.0-\(UUID().uuidString)" }

    private func persistTile(key: String) async throws {
        try sandbox.browse(key: key)
        await offMain {
            sandbox.store.considerPersisting(key: key, z: 14, x: 2638, y: 6357)
        }
    }

    /// The drain waits on ``AutoSaveTileStore/pendingKeySignals()`` and nothing
    /// else ever ends that wait, so a controller released without cancelling it
    /// leaves a task suspended on the store for the rest of the process —
    /// holding the store, and folding for a hike no one can reach. The store
    /// drops the stream's continuation when it terminates, which is the
    /// observable half.
    @Test("releasing the controller ends its drain")
    func releasingTheControllerEndsTheDrain() async {
        var controller: AutoSaveController? = AutoSaveController(
            store: sandbox.store,
            drainInterval: .zero
        )
        #expect(controller != nil, "precondition: the controller was built")

        await settleDelegateHop(until: "the drain to start waiting on the store") {
            sandbox.store.pendingSignalObserverCount == 1
        }
        #expect(
            sandbox.store.pendingSignalObserverCount == 1,
            "precondition: the drain really is waiting, so there is something to end"
        )

        controller = nil

        await settleDelegateHop(until: "the drain to stop waiting on the store") {
            sandbox.store.pendingSignalObserverCount == 0
        }
        #expect(
            sandbox.store.pendingSignalObserverCount == 0,
            "a drain nothing cancels stays suspended on the store for the life of the process"
        )
    }

    /// The negative half of the pair below. `hikeSelectionChanged` installs the
    /// empty corridor synchronously and arms the activation task; the release
    /// then happens with no suspension in between, so the task's continuation —
    /// which resumes on the main actor this test is holding — cannot have
    /// published anything yet. From there `activationTask`'s `guard let self`
    /// is the whole contract, whether the `isolated deinit` has already
    /// cancelled it or is still scheduled behind this test.
    @Test("an activation in flight publishes nothing once the controller is gone")
    func activationCannotPublishAfterRelease() async throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context) { $0.autoSaveTilesEnabled = true }
        var controller: AutoSaveController? = AutoSaveController(
            store: sandbox.store,
            drainInterval: nil
        )
        controller?.hikeSelectionChanged(to: hike)
        controller = nil

        let key = tileKey()
        try await persistTile(key: key)

        #expect(
            !sandbox.isSaved(key),
            "a corridor published for a released controller would claim tiles nothing can ever free"
        )
        #expect(
            hike.autoSavedTileKeys.isEmpty,
            "and nothing can reach the manifest either"
        )
    }

    /// The control, so the assertion above is about the release rather than
    /// about a tile that was never claimable: the same hike, the same tile, a
    /// controller that is still held — and the corridor does land.
    @Test("a held controller does claim that tile")
    func aHeldControllerClaimsTheSameTile() async throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context) { $0.autoSaveTilesEnabled = true }
        let controller = AutoSaveController(store: sandbox.store, drainInterval: nil)
        controller.hikeSelectionChanged(to: hike)
        await controller.waitForActivation()

        let key = tileKey()
        try await persistTile(key: key)

        #expect(sandbox.isSaved(key), "precondition for the release test: this tile is claimable")
        controller.flushPendingKeys()
        #expect(hike.autoSavedTileKeys.contains(key))
    }
}
