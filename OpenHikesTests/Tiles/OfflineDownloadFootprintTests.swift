//
//  OfflineDownloadFootprintTests.swift
//  OpenHikesTests
//
//  A complete download lists no keys: its claim is a grid recomputed whenever
//  storage is measured or trimmed. It used to be recomputed from the route the
//  hike has *now*, so redrawing a trail after saving its map — here, or on
//  another device — moved the claim onto tiles nobody fetched and abandoned
//  the ones that were (#748). The grid is recomputed from the box the run was
//  planned over instead, and this suite holds the claim to the bytes.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import SwiftData
import Testing

@MainActor
@Suite("Offline download footprint")
struct OfflineDownloadFootprintTests {
    /// Stadia for its download policy, with a template pointing nowhere since
    /// every save is injected.
    private static let source = ActiveTileSource(
        providerID: TileProvider.stadiaOutdoors.id,
        urlTemplate: "https://example.invalid/{z}/{x}/{y}.png",
        maximumZ: 16
    )

    /// Ten degrees east of the drawn line — far enough that not one tile is
    /// shared even at the overview zoom.
    private enum Line {
        static let south = 47.63
        static let north = 47.64
        static let longitude = 12.86
        static let movedLongitude = 22.86
    }

    private let context: ModelContext

    init() throws {
        context = try Fixture.modelContext()
    }

    private static func draft(longitude: Double) -> TrailDraft {
        let draft = TrailDraft()
        draft.append(CLLocationCoordinate2D(latitude: Line.south, longitude: longitude))
        draft.append(CLLocationCoordinate2D(latitude: Line.north, longitude: longitude))
        return draft
    }

    private func savedTrail() throws -> Hike {
        try #require(
            TrailDraftSave.hike(from: Self.draft(longitude: Line.longitude), named: "Ridge", into: context).hike
        )
    }

    private func redraw(_ hike: Hike) throws {
        let outcome = TrailDraftSave.update(
            hike,
            from: Self.draft(longitude: Line.movedLongitude),
            openedWith: [],
            into: context
        )
        _ = try #require(outcome.hike)
        #expect(hike.route.allSatisfy { $0.longitude == Line.movedLongitude })
    }

    /// The keys a download of `hike`'s current line fetches, and the complete
    /// record a run that fetched them all writes.
    private func plannedDownload(of hike: Hike) async throws -> (record: OfflineDownloadRecord, keys: Set<String>) {
        let plan = try await OfflineTileDownloader.plannedTiles(
            for: hike.route,
            maxZoom: Self.source.maximumZ,
            providerID: Self.source.providerID
        )
        let keys = Set(plan.tiles.map { $0.cacheKey(providerID: Self.source.providerID) })
        let record = try #require(
            OfflineTileDownloader.coverage(
                savedKeys: keys.sorted(),
                plannedCount: plan.tiles.count,
                source: Self.source,
                footprint: plan.footprint
            )
        )
        #expect(record.savedTileKeys.isEmpty, "a run that saved its whole plan writes the compact record")
        return (record, keys)
    }

    private func claimed(by hike: Hike) async throws -> Set<String> {
        let ownership = TileOwnership(hike)
        return try await offMain { try ownership.tileKeys() }
    }

    /// Every tile a download of `hike`'s current line would fetch — the grid a
    /// claim must not wander onto after an edit.
    private func currentGrid(of hike: Hike) -> Set<String> {
        Set(
            OfflineTileDownloader.tileKeys(
                for: hike.route.map(\.clCoordinate),
                providerID: Self.source.providerID,
                providerMaxZoom: TileProvider.stadiaOutdoors.maximumZ,
                maxZoom: Self.source.maximumZ
            )
        )
    }

    // MARK: Editing the line

    @Test("redrawing a trail leaves its saved map claiming the tiles that were fetched")
    func anEditKeepsTheFetchedTiles() async throws {
        let hike = try savedTrail()
        let download = try await plannedDownload(of: hike)
        hike.mergeOfflineDownload(download.record)
        #expect(try await claimed(by: hike) == download.keys)

        try redraw(hike)

        let claim = try await claimed(by: hike)
        #expect(claim == download.keys)
        #expect(claim.isDisjoint(with: currentGrid(of: hike)), "nothing on the new line was ever fetched")
    }

    /// A record written before the box was kept has nothing but the route to be
    /// recomputed from, so the edit has to pin it to the line it was derived
    /// from before that line goes.
    @Test("an edit pins a download recorded without its box to the line it had")
    func anEditPinsAnUnboxedDownload() async throws {
        let hike = try savedTrail()
        let download = try await plannedDownload(of: hike)
        var unboxed = download.record
        unboxed.footprint = nil
        hike.offlineDownloads = [unboxed]
        #expect(try await claimed(by: hike) == download.keys)

        try redraw(hike)

        #expect(hike.offlineDownloads.map(\.footprint) == [download.record.footprint])
        #expect(try await claimed(by: hike) == download.keys)
    }

    /// The route revision the run was planned against is not what the commit
    /// checks, because it does not have to be: the record says which box its
    /// tiles came from, so a redraw between the plan and the claim changes
    /// nothing about what the claim is true of.
    @Test("a run planned before a redraw claims what it fetched, not the new line")
    func anInFlightRunClaimsItsPlan() async throws {
        let hike = try savedTrail()
        let planned = try await plannedDownload(of: hike)
        let gate = Gate()
        let downloader = OfflineTileDownloader(
            isOnline: { true },
            registry: OfflineDownloadRegistry(),
            saveTile: { _, _ in
                await gate.wait()
                return true
            }
        )
        let claim: OfflineTileDownloader.Claim = { record in try OfflineDownloadClaim.commit(record, for: hike) }
        downloader.start(route: hike.route, source: Self.source, claim: claim)
        await downloader.waitForPlanning()

        try redraw(hike)
        await gate.open()
        await downloader.waitForCurrentRun()

        #expect(downloader.phase == .finished)
        #expect(hike.offlineDownloads.map(\.footprint) == [planned.record.footprint])
        #expect(try await claimed(by: hike) == planned.keys)
    }

    // MARK: What cleanup may take

    /// Two hikes saved the same valley's map, and one is then redrawn
    /// elsewhere. Its tiles are still on disk under the old box, so deleting
    /// the other hike has nothing it may take: every tile it held is still
    /// claimed. Recomputed from the redrawn route, the claim would have let
    /// the delete strip the whole map.
    @Test("deleting a neighbour leaves a redrawn trail's saved map alone")
    func deletingANeighbourSparesARedrawnMap() async throws {
        let redrawn = try savedTrail()
        let neighbour = try savedTrail()
        let download = try await plannedDownload(of: redrawn)
        redrawn.mergeOfflineDownload(download.record)
        neighbour.mergeOfflineDownload(download.record)

        try redraw(redrawn)

        let plan = StoredTileDeletionPlan(doomed: TileOwnership(neighbour), survivors: [TileOwnership(redrawn)])
        #expect(try await offMain { try plan.exclusiveTileKeys() }.isEmpty)
    }

    /// Holds every tile save until the test has done what it needs to do
    /// between the plan and the claim.
    private actor Gate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            guard !isOpen else { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func open() {
            isOpen = true
            for waiter in waiters { waiter.resume() }
            waiters.removeAll()
        }
    }
}
