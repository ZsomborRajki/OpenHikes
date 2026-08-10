//
//  TileOwnership.swift
//  OpenTrails
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
    @MainActor
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
    func tileKeys() -> Set<String> {
        guard hasStoredTiles else { return [] }
        let coordinates = route.map(\.clCoordinate)
        return Set(
            OfflineTileDownloader.storedTileKeys(route: coordinates, offlineDownloads: offlineDownloads)
        ).union(autoSavedTileKeys)
    }

    /// The keys `self` claims that none of `others` do — i.e. exactly what can
    /// be deleted along with this hike without quietly stripping offline
    /// coverage from a hike that's still around and still lists it.
    func exclusiveTileKeys(against others: [TileOwnership]) -> Set<String> {
        var keys = tileKeys()
        for other in others where other.hasStoredTiles {
            keys.subtract(other.tileKeys())
            // Overlapping trails can account for everything; stop paying for
            // the remaining route enumerations once nothing is left to delete.
            if keys.isEmpty { break }
        }
        return keys
    }
}

@MainActor
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
