//
//  HikeDeletionTests+Tiles.swift
//  OpenHikesTests
//
//  The other irreversible half of a whole-hike deletion: the tiles it saved
//  for a valley with no signal.
//
//  `HikeDeletionTests+Photos` pins this ordering for the pictures, and the
//  argument is the same one — except that a tile has a claim in a manifest
//  behind it, so the wrong order costs more. Freeing the files first and then
//  having the save refused brings the manifest back listing tiles that are
//  gone, and nothing can tell: `TileCache.trimCache(claimedBy:)` reads a claim
//  with no file behind it exactly as it reads a claim that is satisfied, so
//  the hike reports a saved map for good and nothing re-downloads it.
//
//  So the deletion is committed first, and the plan it hands back is spent
//  afterwards. What is checked here is that window — every planned tile still
//  on disk as the deletion lands — and the promise the plan itself keeps: a
//  tile a surviving hike also claims is not this hike's to take with it.
//  `StoredTileDeletionTests` asks the same two questions of the hike sheet's
//  Delete button.
//

import Foundation
@testable import OpenHikes
import SwiftData
import Testing

extension HikeDeletionTests {
    /// The tile both hikes claim, and the one only the doomed hike does.
    nonisolated private static let sharedTileKey = "osm/14/8723/5685@2.0-shared"
    nonisolated private static let exclusiveTileKey = "osm/14/8724/5685@2.0-exclusive"

    /// Two saved hikes over the same ground, claiming by auto-saved key so the
    /// claim is exactly the tiles on disk rather than a recomputed route grid.
    private static func hikesSharingATile(
        in context: ModelContext,
        sandbox: TileSandbox
    ) throws -> (doomed: Hike, survivor: Hike) {
        try sandbox.save(key: sharedTileKey)
        try sandbox.save(key: exclusiveTileKey)
        let doomed = Fixture.hike(in: context, title: "On its way out")
        let survivor = Fixture.hike(in: context, title: "Still on the device")
        doomed.autoSavedTileKeys = [sharedTileKey, exclusiveTileKey]
        survivor.autoSavedTileKeys = [sharedTileKey]
        try context.save()
        return (doomed, survivor)
    }

    @Test("a deleted hike is on disk before any of its tiles are freed")
    func deletionSavesBeforeFreeingTiles() async throws {
        let sandbox = TileSandbox()
        let photos = HikePhotoImportTests.Sandbox()
        let context = try Fixture.modelContext()
        let (doomed, survivor) = try Self.hikesSharingATile(in: context, sandbox: sandbox)

        var tilesAtSave: (shared: Bool, exclusive: Bool)?
        let outcome = HikeDeletion.delete(
            doomed,
            among: [doomed, survivor],
            autoSave: AutoSaveController(store: sandbox.store, drainInterval: nil),
            store: photos.store
        ) { modelContext in
            tilesAtSave = (sandbox.isSaved(Self.sharedTileKey), sandbox.isSaved(Self.exclusiveTileKey))
            try modelContext.save()
        }

        guard case let .committed(plan) = outcome, let deletionPlan = plan else {
            Issue.record("a hike holding tiles must be deleted with a plan to free them")
            return
        }
        #expect(
            tilesAtSave?.shared == true && tilesAtSave?.exclusive == true,
            """
            A tile freed before the commit is one a refused save leaves claimed and gone: the hike is \
            back in the list reporting a saved map that no sweep can see is missing.
            """
        )

        await deletionPlan.removeExclusiveTiles(from: sandbox.cache)
        #expect(!sandbox.isSaved(Self.exclusiveTileKey), "and then what only the deleted hike claimed goes")
        #expect(
            sandbox.isSaved(Self.sharedTileKey),
            "the surviving hike downloaded this one too; deleting it would strip a map nothing re-downloads"
        )
        #expect(survivor.autoSavedTileKeys == [Self.sharedTileKey])
    }

    @Test("a refused deletion frees no tiles at all")
    func refusedDeletionFreesNoTiles() throws {
        let sandbox = TileSandbox()
        let photos = HikePhotoImportTests.Sandbox()
        let context = try Fixture.modelContext()
        let (doomed, survivor) = try Self.hikesSharingATile(in: context, sandbox: sandbox)

        let outcome = HikeDeletion.delete(
            doomed,
            among: [doomed, survivor],
            autoSave: AutoSaveController(store: sandbox.store, drainInterval: nil),
            store: photos.store
        ) { _ in
            throw CocoaError(.fileWriteUnknown)
        }

        // A refusal hands back no plan, which is the whole of it: there is
        // nothing for the caller to spend, so nothing is deleted and the hike
        // the walker still has still claims every tile it had.
        guard case .refused = outcome else {
            Issue.record("a save that threw must be reported as a refusal")
            return
        }
        #expect(Set(doomed.autoSavedTileKeys) == [Self.sharedTileKey, Self.exclusiveTileKey])
        #expect(sandbox.isSaved(Self.sharedTileKey))
        #expect(sandbox.isSaved(Self.exclusiveTileKey))
    }
}
