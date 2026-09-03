//
//  HikeLocalStateTests.swift
//  OpenHikesTests
//
//  The sidecar that keeps this device's tile inventory out of iCloud.
//
//  Worth its own suite because the failure it prevents is silent and
//  expensive. ``TileOwnership`` builds the tile claim set from exactly these
//  two arrays, and `TileCache.trimCache(claimedBy:)` deletes whatever no hike
//  claims — so a claim that fails to persist, or one left behind after its
//  hike is gone, is either a user's offline maps deleted or a cache that never
//  shrinks again. Neither shows up as an error.
//

import Foundation
@testable import OpenHikes
import SwiftData
import Testing

@MainActor
@Suite("Hike local state")
struct HikeLocalStateTests {
    private func context() throws -> ModelContext {
        try Fixture.modelContext()
    }

    /// The baseline: the passthroughs on ``Hike`` reach the other store and
    /// come back with what was written.
    @Test("the tile columns write through to the sidecar and read back")
    func passthroughsRoundTrip() throws {
        let context = try context()
        let hike = Fixture.hike(in: context)

        hike.autoSavedTileKeys = ["osm/16/9/9@2.0"]
        hike.offlineDownloads = [
            OfflineDownloadRecord(providerID: "osm", maxZoom: 14, savedTileKeys: ["osm/14/1/1@2.0"])
        ]
        hike.autoSaveTilesEnabled = false
        try context.save()

        #expect(hike.autoSavedTileKeys == ["osm/16/9/9@2.0"])
        #expect(hike.offlineDownloads.first?.savedTileKeys == ["osm/14/1/1@2.0"])
        #expect(!hike.autoSaveTilesEnabled)
        #expect(hike.hasStoredTiles)
    }

    /// A hike that has never saved a tile has no sidecar row at all — the
    /// reads answer from defaults instead of materialising one. Otherwise
    /// opening the hikes list would insert a row per hike.
    @Test("reading a hike that has stored nothing creates no row")
    func readingDoesNotCreateARow() throws {
        let context = try context()
        let hike = Fixture.hike(in: context)

        #expect(hike.autoSavedTileKeys.isEmpty)
        #expect(hike.offlineDownloads.isEmpty)
        #expect(hike.autoSaveTilesEnabled, "on by default, as it always was")
        #expect(!hike.hasStoredTiles)

        let rows = try context.fetch(FetchDescriptor<HikeLocalState>())
        #expect(rows.isEmpty)
    }

    /// The first write is what brings the row into existence, and only one.
    @Test("writing twice reuses the one row")
    func writingReusesOneRow() throws {
        let context = try context()
        let hike = Fixture.hike(in: context)

        hike.autoSavedTileKeys = ["a"]
        hike.autoSaveTilesEnabled = false
        hike.offlineDownloads = [OfflineDownloadRecord(providerID: "osm", maxZoom: 12)]
        try context.save()

        let rows = try context.fetch(FetchDescriptor<HikeLocalState>())
        #expect(rows.count == 1)
        #expect(rows.first?.hikeID == hike.id)
    }

    /// Two hikes are two rows. A shared one would have every hike claiming
    /// every tile, which would make the trim sweep nothing forever.
    @Test("each hike gets its own row")
    func rowsAreNotSharedBetweenHikes() throws {
        let context = try context()
        let first = Fixture.hike(in: context, title: "First")
        let second = Fixture.hike(in: context, title: "Second")

        first.autoSavedTileKeys = ["first"]
        second.autoSavedTileKeys = ["second"]
        try context.save()

        #expect(first.autoSavedTileKeys == ["first"])
        #expect(second.autoSavedTileKeys == ["second"])
        #expect(try context.fetch(FetchDescriptor<HikeLocalState>()).count == 2)
    }

    /// The leak the delete path exists to close: nothing cascades across two
    /// stores, so a sidecar outliving its hike goes on claiming tiles that no
    /// screen can ever show.
    @Test("deleting a hike's local state removes the row")
    func deletingLocalStateRemovesTheRow() throws {
        let context = try context()
        let hike = Fixture.hike(in: context)
        hike.autoSavedTileKeys = ["osm/16/9/9@2.0"]
        try context.save()
        #expect(try context.fetch(FetchDescriptor<HikeLocalState>()).count == 1)

        hike.deleteLocalState()
        context.delete(hike)
        try context.save()

        #expect(try context.fetch(FetchDescriptor<HikeLocalState>()).isEmpty)
    }

    /// A hike that was never inserted has nowhere to put a claim, and must not
    /// pretend otherwise. The fixture in `Fixture` inserts before it
    /// configures for exactly this reason.
    @Test("a hike with no context reports defaults and stores nothing")
    func detachedHikeStoresNothing() throws {
        let context = try context()
        let detached = Hike(title: "Never inserted", distanceMeters: 100)

        detached.autoSavedTileKeys = ["ignored"]
        detached.autoSaveTilesEnabled = false

        #expect(detached.autoSavedTileKeys.isEmpty)
        #expect(detached.autoSaveTilesEnabled)
        #expect(try context.fetch(FetchDescriptor<HikeLocalState>()).isEmpty)
    }

    /// The sidecar survives a save/refetch, which is the whole point of it
    /// being a store rather than a cache.
    @Test("a refetched hike still finds its claims")
    func claimsSurviveARefetch() throws {
        let container = try Fixture.modelContainer()
        let id: UUID
        do {
            let context = ModelContext(container)
            let hike = Fixture.hike(in: context)
            id = hike.id
            hike.autoSavedTileKeys = ["osm/16/9/9@2.0"]
            try context.save()
        }

        let context = ModelContext(container)
        let refetched = try #require(
            try context.fetch(FetchDescriptor<Hike>(predicate: #Predicate { $0.id == id })).first
        )
        #expect(refetched.autoSavedTileKeys == ["osm/16/9/9@2.0"])
    }

    /// ``Hike/mergeOfflineDownload(_:)`` reads and writes the array through
    /// the passthrough, so it is worth checking it still collapses records
    /// rather than accumulating them now that the array lives elsewhere.
    @Test("merging downloads still collapses records through the sidecar")
    func mergingDownloadsWorksThroughThePassthrough() throws {
        let context = try context()
        let hike = Fixture.hike(in: context)

        hike.mergeOfflineDownload(
            OfflineDownloadRecord(providerID: "osm", maxZoom: 14, savedTileKeys: ["a"])
        )
        hike.mergeOfflineDownload(
            OfflineDownloadRecord(providerID: "osm", maxZoom: 14, savedTileKeys: ["b"])
        )

        #expect(hike.offlineDownloads.count == 1)
        #expect(hike.offlineDownloads.first?.savedTileKeys == ["a", "b"])
    }
}
