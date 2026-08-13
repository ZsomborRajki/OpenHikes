//
//  OfflineStorageAccountingTests+Reclaiming.swift
//  OpenTrailsTests
//

import CoreLocation
import Foundation
@testable import OpenTrails
import SwiftData
import Testing

extension StorageAccountingTests {

    // MARK: - Reclaiming storage from Settings

    /// "Delete All Saved Tiles" reclaims disk. It is not a decision about which
    /// hikes should go on saving tiles as they're browsed — but it used to set
    /// `autoSaveTilesEnabled = false` on every hike, silently clearing a
    /// per-hike setting the user had chosen, on a screen that says nothing
    /// about it.
    @Test("deleting every saved tile doesn't turn off anyone's auto-save")
    func deleteAllKeepsAutoSavePreferences() async throws {
        let controller = makeController()
        let selected = Fixture.hike(in: context) { $0.autoSaveTilesEnabled = true }
        let other = Fixture.hike(title: "Other", route: Fixture.loopRoute, in: context) { hike in
            hike.autoSaveTilesEnabled = true
        }
        let optedOut = Fixture.hike(title: "Opted out", in: context) { $0.autoSaveTilesEnabled = false }
        controller.hikeSelectionChanged(to: selected)

        let saved = key(16, 30, 30)
        try await persist(key: saved, tile: tile())

        // `SettingsView.deleteAllTiles`, minus the SwiftUI.
        let resumed = controller.currentHike
        controller.hikeSelectionChanged(to: nil)
        for hike in [selected, other, optedOut] {
            hike.offlineDownloads.removeAll()
            hike.autoSavedTileKeys.removeAll()
        }
        controller.hikeSelectionChanged(to: resumed)
        await removeAllTiles()

        #expect(selected.autoSaveTilesEnabled, "the setting is the user's, not the delete button's")
        #expect(other.autoSaveTilesEnabled)
        #expect(!optedOut.autoSaveTilesEnabled, "and a hike that had it off still has it off")
    }

    /// The other half: auto-save has to still be *running* for the selected
    /// hike afterwards. Stopping it is how the delete flushes pending keys
    /// safely, so the only question is whether it gets started again.
    @Test("deleting every saved tile leaves the selected hike still saving")
    func deleteAllResumesAutoSave() async throws {
        let controller = makeController()
        let selected = Fixture.hike(in: context) { $0.autoSaveTilesEnabled = true }
        controller.hikeSelectionChanged(to: selected)

        let before = key(16, 31, 31)
        try await persist(key: before, tile: tile())

        let resumed = controller.currentHike
        controller.hikeSelectionChanged(to: nil)
        selected.offlineDownloads.removeAll()
        selected.autoSavedTileKeys.removeAll()
        controller.hikeSelectionChanged(to: resumed)
        await removeAllTiles()

        // A tile browsed after the delete is saved against the hike again,
        // which only happens if the store still has it active.
        let after = key(16, 32, 32)
        try await persist(key: after, tile: tile())
        controller.flushPendingKeys()

        #expect(selected.autoSavedTileKeys.contains(after), "auto-save picked up where it left off")
        #expect(!selected.autoSavedTileKeys.contains(before), "and the manifest really was cleared")
    }

    // MARK: - Bounding the cache

    /// The map cache is the one thing here that grows without anyone asking:
    /// every tile MapKit draws is written, and until now nothing ever put a
    /// ceiling on that. A trim is what bounds it.
    @Test("browsing residue past the limit is trimmed back under it")
    func trimBringsCacheUnderTheLimit() async throws {
        let browsed = (0..<8).map { key(16, 20, $0) }
        for key in browsed { try sandbox.browse(key: key) }

        // A limit two tiles wide, so the trim has real work to do.
        let limit = TileStore.tileByteCount * 2
        let freed = await trim(claimedBy: [], limit: limit)
        #expect(freed > 0)

        let remaining = await bytes(browsed)
        #expect(remaining <= limit, "the cache is back inside its bound")
    }

    /// The bound is on the cache, not on offline maps. A hike's saved tiles are
    /// what the user has for a trail with no signal, so no size limit may take
    /// them — however old they are.
    @Test("a trim never takes offline coverage, however old")
    func trimSparesCoverage() async throws {
        let controller = makeController()
        let hike = Fixture.hike(in: context)
        controller.hikeSelectionChanged(to: hike)

        let saved = key(16, 21, 0)
        try await persist(key: saved, tile: tile())
        controller.flushPendingKeys()
        // Older than anything else on disk, so a trim that could take it would.
        try sandbox.age(key: saved, byDays: 400)

        let browsed = (1..<6).map { key(16, 21, $0) }
        for key in browsed { try sandbox.browse(key: key) }

        let claimed = await claimedKeys(of: hike)
        let freed = await trim(claimedBy: claimed, limit: TileStore.tileByteCount)
        #expect(freed > 0, "precondition: the trim did something")
        #expect(await bytes([saved]) > 0, "the hike's offline map is not the cache's to reclaim")
        #expect(sandbox.isSaved(saved))
    }

    /// What goes is the ground the user has been away from longest — a tile
    /// fetched moments ago is the likeliest to be wanted again.
    @Test("the oldest tiles are the ones evicted")
    func trimEvictsOldestFirst() async throws {
        let stale = [key(16, 22, 0), key(16, 22, 1)]
        let fresh = [key(16, 22, 2), key(16, 22, 3)]
        for key in stale + fresh { try sandbox.browse(key: key) }
        for key in stale { try sandbox.age(key: key, byDays: 90) }

        // Four tiles on disk and room for three: the trim goes to 80% of the
        // limit rather than sitting exactly on it, so it takes two — which is
        // enough to see *which* two.
        _ = await trim(claimedBy: [], limit: TileStore.tileByteCount * 3)

        #expect(stale.allSatisfy { !sandbox.isBrowsed($0) }, "the 90-day-old tiles go")
        #expect(fresh.allSatisfy { sandbox.isBrowsed($0) }, "the ones just fetched stay")
    }

    /// Housekeeping runs on every launch, so the common case — a cache well
    /// inside its bound — has to cost nothing and delete nothing.
    @Test("a cache under the limit is left alone")
    func trimBelowLimitIsANoOp() async throws {
        let browsed = (0..<3).map { key(16, 23, $0) }
        for key in browsed { try sandbox.browse(key: key) }

        let freed = await trim(claimedBy: [], limit: TileCache.cacheByteLimit)
        #expect(freed == 0)
        #expect(browsed.allSatisfy { sandbox.isBrowsed($0) })
    }

    // MARK: - Expiration

    @Test("launch cleanup removes tiles after seven days from both disk tiers")
    func launchCleanupRemovesExpiredTiles() async throws {
        let staleBrowsed = key(16, 24, 0)
        let staleSaved = key(16, 24, 1)
        let freshBrowsed = key(16, 24, 2)
        try sandbox.browse(key: staleBrowsed)
        try sandbox.browse(key: staleSaved)
        try sandbox.browse(key: freshBrowsed)
        #expect(await promoteCachedTile(forKey: staleSaved))
        try sandbox.age(key: staleBrowsed, byDays: 8)
        try sandbox.age(key: staleSaved, byDays: 8)

        let removed = await removeExpiredTiles()

        #expect(removed >= 2)
        #expect(!sandbox.isBrowsed(staleBrowsed))
        #expect(!sandbox.isSaved(staleSaved))
        #expect(sandbox.isBrowsed(freshBrowsed), "tiles inside the seven-day TTL remain cached")
    }

    @Test("an expired tile is deleted instead of being displayed")
    func displayLookupRejectsExpiredTile() async throws {
        let stale = key(16, 25, 0)
        try sandbox.browse(key: stale)
        try sandbox.age(key: stale, byDays: 8)
        let unavailableURL = try #require(URL(string: "file:///expired-tile-must-not-load"))

        let image = await sandbox.cache.loadTile(forKey: stale, url: unavailableURL)

        #expect(image == nil)
        #expect(!sandbox.isBrowsed(stale))
    }

}
