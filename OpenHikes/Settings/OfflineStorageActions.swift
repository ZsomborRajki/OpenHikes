//
//  OfflineStorageActions.swift
//  OpenHikes
//
//  What the Settings "Offline Storage" section is allowed to measure and
//  delete, and what authorises it.
//
//  This is the launch sweeps' rule on the other path that spends a tile claim
//  set — see ``OpenHikesModel/trimTileCache(_:limit:fetchingHikes:)`` — and it
//  is the same sentence. `TileCache.removeTiles(unclaimedBy:)` walks the
//  durable directory as well as the browsing one and tells the two kinds of
//  tile apart by nothing but that set, so a set built from a fetch that failed
//  is not the cautious answer: it is the maximally destructive one. Every tile
//  every hike downloaded for a valley with no signal becomes unclaimed at the
//  same instant, and Clear Map Cache frees the lot — under a footer promising
//  that clearing it "costs you nothing offline".
//
//  Which is why all of this is `static` and closure-driven rather than three
//  methods on the view: nothing makes a `ModelContext` throw on demand — a
//  fetch against a schema it does not know returns an empty result rather than
//  an error — so without this seam every refusal below could be rewritten as
//  `?? []` and the whole bundle would stay green.
//

import Foundation

/// The three storage jobs behind the section's two byte rows and its two
/// buttons.
///
/// Each takes its cache and its fetch, and each answers in two phases: the
/// claims are snapshotted synchronously, on the main actor, where reading
/// SwiftData is legal, and only the resulting value types cross onto the
/// concurrent executor. The enumeration is O(tile budget) trig per download
/// record and the deletions `stat` and unlink every file they touch — none of
/// it may run on the main thread, and `TileCache` asserts as much.
///
/// Every entry point hands its work back as a task rather than running it,
/// and `nil` *is* the refusal: a claim set that could not be established never
/// reaches the cache, so there is nothing to return. That gives the caller
/// something to wait on before re-measuring, and gives a test something to
/// await before reading the disk — without which the only detector of a
/// refusal that was not honoured would be whether a `.utility` task happened
/// to outrun an `#expect`.
enum OfflineStorageActions {
    /// The bytes behind "Saved for offline" and "Map cache", split by the
    /// claim set, or `nil` if the claims could not be established.
    ///
    /// Refusing to measure is not merely honest here, it is the brake: `nil`
    /// is what the rows already show before the first measurement — "…", with
    /// both buttons disabled — so a claim set that cannot be built leaves the
    /// section unable to delete anything, rather than reporting every durable
    /// tile on the device as reclaimable cache.
    ///
    /// The inner task takes no explicit priority so the first measurement
    /// keeps the one the view's `.task` gave it.
    static func measureDiskUsage(
        in cache: TileCache,
        fetchingHikes fetch: () throws -> [Hike]
    ) -> Task<TileCache.DiskUsage?, Never>? {
        guard let claims = try? TileOwnership.claims(of: fetch()) else { return nil }
        return Task { await diskUsage(claimedBy: claims, in: cache) }
    }

    /// "Clear Map Cache": frees every tile no hike claims, and nothing at all
    /// when the claims could not be established.
    ///
    /// A bulk download in flight is stood down first, because its tiles are
    /// exactly the ones no hike claims *yet* — see ``OfflineDownloadRegistry``.
    /// Left running, they would be freed here and its completion would claim
    /// them back a moment later.
    static func clearMapCache(
        in cache: TileCache,
        downloads: OfflineDownloadRegistry = .shared,
        fetchingHikes fetch: () throws -> [Hike]
    ) -> Task<Void, Never>? {
        guard let claims = try? TileOwnership.claims(of: fetch()) else { return nil }
        downloads.standDown()
        return Task(priority: .utility) { await removeTiles(unclaimedBy: claims, from: cache) }
    }

    /// "Delete All Saved Tiles": empties every hike's manifest and then the
    /// cache itself — or touches neither.
    ///
    /// This one deletes everything by design, so a claim set buys it nothing;
    /// what it needs the fetch for is the *other* half of the promise, which
    /// is that no hike is left listing tiles that are gone. A fetch that
    /// failed would delete the tiles and clear no manifest, so the hike sheets
    /// would go on reporting offline coverage that no longer exists.
    ///
    /// Which is the promise a download still running breaks from the other
    /// end, so one is stood down once the manifests are clear and before the
    /// deletion runs: its completion cannot then write a record into a
    /// manifest this just emptied. See ``OfflineDownloadRegistry``.
    static func deleteAllTiles(
        in cache: TileCache,
        downloads: OfflineDownloadRegistry = .shared,
        fetchingHikes fetch: () throws -> [Hike]
    ) -> Task<Void, Never>? {
        guard (try? clearManifests(fetchingHikes: fetch)) != nil else { return nil }
        downloads.standDown()
        return Task(priority: .utility) { await removeAllTiles(from: cache) }
    }

    /// Empties every hike's tile manifest, all of them or none.
    ///
    /// Resolved in full before anything is written, for two reasons. A hike
    /// whose sidecar cannot be read must not be written *through*: the
    /// passthrough setter materialises a fresh record when the lookup comes
    /// back empty, which would leave the real row behind — still claiming
    /// tiles this is about to delete — beside a newly inserted empty one. And
    /// a failure halfway would leave the hikes it had already reached with
    /// empty manifests and their tiles still on disk, which is the launch
    /// trim's problem a moment later.
    private static func clearManifests(fetchingHikes fetch: () throws -> [Hike]) throws {
        let hikes = try fetch()
        let holders = try hikes.filter { try $0.resolveLocalState() != nil }
        for hike in holders where hike.hasStoredTiles {
            hike.offlineDownloads.removeAll()
            hike.autoSavedTileKeys.removeAll()
            // `autoSaveTilesEnabled` is deliberately left alone. Reclaiming
            // disk is not a decision about whether a hike should keep saving
            // tiles, and this used to silently turn that setting off for every
            // hike the user had ever enabled it on.
        }
    }

    /// The union is O(tile budget) trig per download record, so it belongs
    /// inside the `@concurrent` work below rather than on the way in.
    nonisolated private static func keys(
        of claims: [TileOwnership]
    ) throws(CancellationError) -> Set<String> {
        var keys = Set<String>()
        for claim in claims {
            keys.formUnion(try claim.tileKeys())
        }
        return keys
    }

    /// The work itself, each `@concurrent` so it runs on the concurrent
    /// executor while staying in the caller's task.
    ///
    /// A cancelled key enumeration deletes nothing rather than a partial set,
    /// for the same reason a failed fetch does: cache keys carry no hike
    /// identity, so an under-reported claim set frees tiles that a surviving
    /// hike still needs.
    @concurrent
    private static func diskUsage(
        claimedBy claims: [TileOwnership],
        in cache: TileCache
    ) async -> TileCache.DiskUsage? {
        guard let keys = try? keys(of: claims) else { return nil }
        return cache.diskUsage(claimedBy: keys)
    }

    @concurrent
    private static func removeTiles(unclaimedBy claims: [TileOwnership], from cache: TileCache) async {
        guard let keys = try? keys(of: claims) else { return }
        cache.removeTiles(unclaimedBy: keys)
    }

    @concurrent
    private static func removeAllTiles(from cache: TileCache) async {
        cache.removeAllTiles()
    }
}
