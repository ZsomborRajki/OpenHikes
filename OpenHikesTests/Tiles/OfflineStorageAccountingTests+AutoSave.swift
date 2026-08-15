//
//  OfflineStorageAccountingTests+AutoSave.swift
//  OpenHikesTests
//

import CoreLocation
import Foundation
@testable import OpenHikes
import SwiftData
import Testing

extension StorageAccountingTests {

    // MARK: - Tiles auto-save writes but forgets

    /// A tile is durable on disk the moment it's saved, but only enters the
    /// hike's manifest at the next 2-second drain. Tearing the store's active
    /// hike down in between discards the pending set, and with it the only
    /// record that those bytes belong to anything — they are then invisible
    /// to the hike's size, to its Delete button, and to deleting the hike.
    @Test("deselecting a hike keeps the tiles it just saved accounted for")
    func deselectingFoldsInPendingKeys() async throws {
        let controller = makeController()
        let hike = Fixture.hike(in: context)
        controller.hikeSelectionChanged(to: hike)
        await controller.waitForActivation()

        let saved = key(17, 6, 6)
        try await persist(key: saved, tile: tile(z: 17))
        // No flush: the drain timer hasn't come round yet.
        controller.hikeSelectionChanged(to: nil)

        #expect(try await bytes([saved]) > 0, "precondition: the tile is durably on disk")
        #expect(hike.autoSavedTileKeys.contains(saved), "otherwise nothing will ever free it")
    }

    @Test("switching hikes keeps the outgoing hike's newest tiles accounted for")
    func switchingHikesFoldsInPendingKeys() async throws {
        let controller = makeController()
        let first = Fixture.hike(in: context)
        let second = Fixture.hike(in: context, title: "Second", route: Fixture.loopRoute)
        controller.hikeSelectionChanged(to: first)
        await controller.waitForActivation()

        let saved = key(17, 7, 7)
        try await persist(key: saved, tile: tile(z: 17))
        controller.hikeSelectionChanged(to: second)

        #expect(first.autoSavedTileKeys.contains(saved))
        #expect(!second.autoSavedTileKeys.contains(saved), "the tile belongs to the trail it was saved for")
    }

    @Test("turning auto-save off keeps what it already saved accounted for")
    func disablingFoldsInPendingKeys() async throws {
        let controller = makeController()
        let hike = Fixture.hike(in: context)
        controller.hikeSelectionChanged(to: hike)
        await controller.waitForActivation()

        let saved = key(17, 8, 8)
        try await persist(key: saved, tile: tile(z: 17))
        controller.setEnabled(false, for: hike)

        #expect(hike.autoSavedTileKeys.contains(saved))
    }

    /// Deleting the hike the user is looking at is the case where the pending
    /// window matters most: the tiles are durably on disk and no manifest names
    /// them, so the delete path has nothing to free them by.
    @Test("deleting a hike frees even the tiles it saved a moment ago")
    func deletingFreesPendingTiles() async throws {
        let controller = makeController()
        let hike = Fixture.hike(in: context)
        controller.hikeSelectionChanged(to: hike)
        await controller.waitForActivation()

        let saved = key(17, 9, 9)
        try await persist(key: saved, tile: tile(z: 17))
        #expect(try await bytes([saved]) > 0, "precondition: the tile is durably on disk")

        // No flush first: the delete path is responsible for that itself.
        await deleteHike(hike, using: controller)
        #expect(try await bytes([saved]) == 0)
    }

    /// The flush a delete performs must not hand one trail's tiles to
    /// another: a tile saved for the doomed hike is still shared coverage if a
    /// surviving hike's own manifest claims it.
    @Test("a surviving hike's tiles are not freed by deleting another")
    func deletingKeepsSharedTiles() async throws {
        let controller = makeController()
        let doomed = Fixture.hike(in: context)
        let survivor = Fixture.hike(in: context, title: "Survivor")
        controller.hikeSelectionChanged(to: doomed)
        await controller.waitForActivation()

        let shared = key(17, 10, 10)
        try await persist(key: shared, tile: tile(z: 17))
        controller.flushPendingKeys()
        survivor.autoSavedTileKeys = [shared]

        await deleteHike(doomed, using: controller, survivors: [survivor])
        #expect(try await bytes([shared]) > 0, "the surviving hike still lists this tile")
    }

    @Test("clearing one hike's offline tiles keeps another hike's shared coverage")
    func clearingStoredTilesKeepsSharedTiles() async throws {
        let controller = makeController()
        let cleared = Fixture.hike(in: context, title: "Cleared")
        let survivor = Fixture.hike(in: context, title: "Survivor")
        controller.hikeSelectionChanged(to: cleared)
        await controller.waitForActivation()

        let shared = key(17, 11, 11)
        try await persist(key: shared, tile: tile(z: 17))
        controller.flushPendingKeys()
        survivor.autoSavedTileKeys = [shared]

        await clearStoredTiles(for: cleared, among: [cleared, survivor], using: controller)

        #expect(cleared.autoSavedTileKeys.isEmpty)
        #expect(cleared.offlineDownloads.isEmpty)
        #expect(survivor.autoSavedTileKeys == [shared])
        #expect(try await bytes([shared]) > 0, "the surviving hike still owns this tile")
    }
}
