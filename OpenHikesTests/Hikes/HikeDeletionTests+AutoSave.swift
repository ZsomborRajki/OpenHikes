//
//  HikeDeletionTests+AutoSave.swift
//  OpenHikesTests
//
//  The other thing a whole-hike deletion has to stand down first, and put
//  back if the store refuses it.
//
//  `AutoSaveController.hikeWillBeDeleted` is not a notification: it folds the
//  last drain window's tile keys out of `AutoSaveTileStore`'s pending set and
//  into the hike's manifest — an unsaved write — and then stops saving. A
//  rollback takes that write back with the deletion, and the selection never
//  changed, so nothing re-arms the controller on its own. Left alone, a
//  transient save failure would cost the user a walk's worth of durable tiles
//  (claimed by nothing, deleted at the next launch trim) and silently stop
//  auto-saving for a hike that is still on screen.
//
//  These call the sequence `MapSheet.delete(_:among:)` calls rather than
//  restating it, the way `SheetRouteTests` does: a mirrored rule pins the
//  reasoning but cannot fail when the call site drifts away from it.
//

import Foundation
@testable import OpenHikes
import SwiftData
import Testing

extension HikeDeletionTests {
    /// The ridge fixture's own tile, inside the corridor the hike builds, so
    /// the store claims it the way it does in the app.
    nonisolated private static let tileKey = "osm/14/2638/6357@2.0-standdown"
    nonisolated private static let tileZ = 14
    nonisolated private static let tileX = 2638
    nonisolated private static let tileY = 6357

    /// A hike that is auto-saving, with one tile saved since the last drain:
    /// on disk, claimed in memory, and not yet in the manifest. Exactly the
    /// window `hikeWillBeDeleted` exists for.
    private static func autoSavingHike(
        in context: ModelContext,
        sandbox: TileSandbox
    ) async throws -> (Hike, AutoSaveController) {
        let hike = Fixture.hike(in: context) { $0.autoSaveTilesEnabled = true }
        try context.save()
        let controller = AutoSaveController(store: sandbox.store, drainInterval: nil)
        controller.hikeSelectionChanged(to: hike)
        await controller.waitForActivation()

        try sandbox.browse(key: tileKey)
        await offMain {
            sandbox.store.considerPersisting(key: tileKey, z: tileZ, x: tileX, y: tileY)
        }
        try #require(sandbox.isSaved(tileKey), "precondition: the tile really did reach durable storage")
        try #require(
            hike.autoSavedTileKeys.isEmpty,
            "precondition: the claim is still only in the store's pending set"
        )
        return (hike, controller)
    }

    @Test("a refused deletion gives the hike back its tile claims and its auto-save")
    func refusedDeletionRestoresAutoSave() async throws {
        let sandbox = TileSandbox()
        let photos = HikePhotoImportTests.Sandbox()
        let context = try Fixture.modelContext()
        let (hike, controller) = try await Self.autoSavingHike(in: context, sandbox: sandbox)

        let outcome = HikeDeletion.delete(
            hike,
            among: [hike],
            autoSave: controller,
            store: photos.store
        ) { _ in
            throw CocoaError(.fileWriteUnknown)
        }

        guard case .refused = outcome else {
            Issue.record("a save that threw must be reported as a refusal")
            return
        }
        // The claim, which the rollback took back out of the manifest along
        // with the deletion. Without it the tile is on disk spoken for by
        // nobody, and the next launch trim deletes a map the user still has
        // the hike for.
        #expect(hike.autoSavedTileKeys == [Self.tileKey])
        // And the controller, which nothing else would re-arm: the selection
        // never changed, so there is no `onChange` to come.
        #expect(controller.currentHike?.id == hike.id)
        #expect(sandbox.isSaved(Self.tileKey), "and the tile itself is untouched")
    }

    @Test("a committed deletion folds the drain window in before it plans the tiles")
    func committedDeletionFoldsBeforePlanning() async throws {
        let sandbox = TileSandbox()
        let photos = HikePhotoImportTests.Sandbox()
        let context = try Fixture.modelContext()
        let (hike, controller) = try await Self.autoSavingHike(in: context, sandbox: sandbox)

        let outcome = HikeDeletion.delete(
            hike,
            among: [hike],
            autoSave: controller,
            store: photos.store
        )

        guard case let .committed(plan) = outcome else {
            Issue.record("the deletion was refused")
            return
        }
        // A plan at all is the assertion: it is built from the manifest, and
        // the only thing in this hike's manifest is the key folded in by the
        // stand-down a moment earlier. Planning first would have left that
        // tile out of the plan and on disk, claimed by a hike that is gone.
        #expect(plan != nil)
        #expect(controller.currentHike == nil, "and auto-save stays down for a hike that really went")
        #expect(try context.fetch(FetchDescriptor<Hike>()).isEmpty)
    }
}
