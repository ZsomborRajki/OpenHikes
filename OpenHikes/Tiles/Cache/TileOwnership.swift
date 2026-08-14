//
//  TileOwnership.swift
//  OpenHikes
//
//  Which cached tiles a hike lays claim to.
//
//  Tile cache keys are purely geographic — `providerID/z/x/y@scale`, with no
//  hike identity in them — so two hikes in the same area claim literally the
//  same keys, and at low zoom (where one tile spans a region) *every* hike in
//  the same country claims the same handful. That makes "delete this hike's
//  tiles" the wrong question: the right one is which of its tiles nothing
//  else still needs, which is what this type exists to answer.
//
//  A plain value snapshot of a `Hike`, taken on the main actor, precisely so
//  the expensive part can run off it: `tileKeys()` does O(tile budget) trig
//  per download record, and SwiftData models can't leave the main actor
//  anyway.
//

import CoreLocation
import Foundation

nonisolated struct TileOwnership: Sendable {
    private let route: [RouteCoordinate]
    private let offlineDownloads: [OfflineDownloadRecord]
    private let autoSavedTileKeys: [String]

    /// Snapshots `hike`'s claims. Call `AutoSaveController.flushPendingKeys()`
    /// first if tiles may have been auto-saved since the last periodic flush —
    /// this reads the manifest, and anything not yet folded into it is
    /// invisible here.
    init(_ hike: Hike) {
        route = hike.route
        offlineDownloads = hike.offlineDownloads
        autoSavedTileKeys = hike.autoSavedTileKeys
    }

    /// Whether this hike has any stored tiles at all — the cheap check that
    /// keeps `tileKeys()`'s real work off hikes that were never saved offline.
    var hasStoredTiles: Bool { !offlineDownloads.isEmpty || !autoSavedTileKeys.isEmpty }

    /// Every cache key this hike claims: the tiles each bulk download would
    /// have covered, plus the ones auto-saved while it was browsed.
    ///
    /// Recomputed from the route rather than stored, matching how the
    /// downloader enumerates them in the first place.
    func tileKeys() throws(CancellationError) -> Set<String> {
        guard hasStoredTiles else { return [] }
        let coordinates = route.map(\.clCoordinate)
        return try Set(
            OfflineTileDownloader.storedTileKeys(
                route: coordinates,
                offlineDownloads: offlineDownloads
            )
        ).union(autoSavedTileKeys)
    }

    /// The keys `self` claims that none of `others` do — i.e. exactly what can
    /// be deleted along with this hike without quietly stripping offline
    /// coverage from a hike that's still around and still lists it.
    ///
    /// Cancellation propagates rather than degrading: a half-enumerated
    /// survivor would under-report its claims, and the caller would delete
    /// tiles that hike still needs. Throwing means nothing is deleted instead.
    func exclusiveTileKeys(
        against others: [Self]
    ) throws(CancellationError) -> Set<String> {
        var keys = try tileKeys()
        for other in others where other.hasStoredTiles {
            keys.subtract(try other.tileKeys())
            // Overlapping trails can account for everything; stop paying for
            // the remaining route enumerations once nothing is left to delete.
            if keys.isEmpty { break }
        }
        return keys
    }
}

/// Snapshots one hike's tile claims and every surviving claim in one
/// main-actor pass, then answers the expensive deletion question off-main.
nonisolated struct StoredTileDeletionPlan: Sendable {
    private let doomed: TileOwnership
    private let survivors: [TileOwnership]

    init(removing hike: Hike, among hikes: [Hike]) {
        doomed = TileOwnership(hike)
        survivors = hikes
            .filter { $0.id != hike.id && $0.hasStoredTiles }
            .map(TileOwnership.init) // swiftlint:disable:this prefer_self_in_static_references
    }

    func exclusiveTileKeys() throws(CancellationError) -> Set<String> {
        try doomed.exclusiveTileKeys(against: survivors)
    }

    /// Enumerates and frees this plan's exclusive tiles on the concurrent
    /// executor. `@concurrent` rather than a detached task: a `Task` started
    /// from the main actor inherits its isolation, and both the enumeration
    /// and the file removal assert they are off the main thread.
    @concurrent
    func removeExclusiveTiles(from cache: TileCache) async {
        let keys: Set<String>
        do throws(CancellationError) {
            keys = try exclusiveTileKeys()
        } catch {
            // Cancelled mid-enumeration: a partial survivor set under-reports
            // what is still claimed, so delete nothing rather than strip a
            // surviving hike's offline coverage.
            return
        }
        guard !keys.isEmpty else { return }
        cache.removeTiles(forKeys: Array(keys))
    }
}

extension Hike {
    /// Whether this hike has any stored tiles — answered from two small
    /// arrays, without touching `route`.
    ///
    /// The pre-filter for building ``TileOwnership`` snapshots: a delete has
    /// to consider every *other* hike, and faulting in a few hundred full
    /// routes to discover that none of them ever saved a tile is work worth
    /// not doing on the main actor.
    var hasStoredTiles: Bool { !offlineDownloads.isEmpty || !autoSavedTileKeys.isEmpty }
}
