//
//  OpenHikesModel+LaunchSweeps.swift
//  OpenHikes
//
//  The two sweeps that run once at launch, and what authorizes them to delete
//  anything.
//
//  Files written outside SwiftData need an owner and a backstop: photo and tile
//  deletion is fire-and-forget, so termination can leave a file on disk with
//  nothing pointing at it and no screen that could ever show it again. These
//  are that backstop, and they are the most dangerous code in the app — both
//  hand a claim set to something whose whole job is removing what is not in it.
//
//  Which is why every entry point here is closure-driven and `static`: neither
//  `TileCache.trimCache(claimedBy:)` nor `HikePhotoStore.reclaimOrphans(claimedBy:)`
//  can tell an honestly empty claim set from one a failed fetch produced, and
//  nothing else makes a `ModelContext` throw on demand.
//

import Foundation
import SwiftData

// MARK: - Claims

/// What authorizes the two launch sweeps to delete anything.
///
/// These `throw` rather than returning an empty set: the distinction between
/// "nothing is claimed" and "the claims could not be read" is in the type, so
/// the call sites below can only spend a claim set they actually have.
extension OpenHikesModel {
    /// Every hike that is holding tiles, as the ownership records a trim is
    /// measured against.
    ///
    /// Two reads can fail here, not one: the fetch, and the device-local
    /// sidecar each claim is actually stored in. ``TileOwnership/claims(of:)``
    /// propagates both — a hike that reports no tiles because its sidecar
    /// could not be read is as absent from a claim set as one the fetch never
    /// returned, and just as destructive.
    static func tileClaims(
        fetchingHikes fetch: () throws -> [Hike]
    ) throws -> [TileOwnership] {
        try TileOwnership.claims(of: fetch())
    }

    /// Every file name any hike's photos occupy — the picture and its
    /// thumbnail both, since a thumbnail left unclaimed is deleted and
    /// silently re-rendered.
    static func photoClaims(
        fetchingHikes fetch: () throws -> [Hike]
    ) rethrows -> Set<String> {
        var claimed = Set<String>()
        for photo in try fetch().flatMap(\.photos) {
            claimed.insert(photo.fileName)
            claimed.insert(photo.thumbnailFileName)
        }
        return claimed
    }
}

// MARK: - Sweeps

extension OpenHikesModel {
    /// Evicts cached tiles no hike claims any more, down to the cache limit.
    ///
    /// A fetch that fails sweeps nothing rather than sweeping with an empty
    /// claim set: ``TileCache/trimCache(claimedBy:limit:)`` tells a hike's
    /// downloaded offline map apart from browsing residue by nothing but that
    /// set, so an empty one makes every durable tile evictable.
    func trimTileCache(in modelContext: ModelContext) {
        // Auto-save can have tiles on disk that no manifest claims yet.
        autoSaveController.flushPendingKeys()
        Self.trimTileCache(TileCache.shared) {
            try modelContext.fetch(FetchDescriptor<Hike>())
        }
    }

    /// The rule itself, with the cache and the fetch handed in.
    ///
    /// `static` and closure-driven for the same reason
    /// ``tileClaims(fetchingHikes:)`` is, and it is the same sentence: the
    /// branch that matters is the failing one, and nothing makes a
    /// `ModelContext` throw on demand — a fetch against a schema it doesn't
    /// know returns an empty result rather than an error. Without this seam
    /// the `guard` below could be rewritten as `?? []` and every test in the
    /// bundle would still pass, while the app deleted every durably saved
    /// tile on the device at the next launch.
    ///
    /// `limit` is a parameter for the reason
    /// ``TileCache/trimCache(claimedBy:limit:)``'s own is: so a test can reach
    /// the trim with a handful of tiles rather than half a gigabyte.
    static func trimTileCache(
        _ cache: TileCache,
        limit: Int64 = TileCache.cacheByteLimit,
        fetchingHikes fetch: () throws -> [Hike]
    ) {
        guard let claims = try? tileClaims(fetchingHikes: fetch) else { return }

        TileCache.scheduleMaintenance {
            // A cancelled enumeration trims nothing rather than a partial
            // claim set: an under-reported claim is indistinguishable from an
            // unclaimed tile, and would evict a hike's saved map.
            var keys = Set<String>()
            for ownership in claims {
                guard let claimed = try? ownership.tileKeys() else { return }
                keys.formUnion(claimed)
            }
            cache.trimCache(claimedBy: keys, limit: limit)
        }
    }

    /// Deletes photo files that no hike claims any more.
    ///
    /// The companion to ``trimTileCache(in:)``, and run in the same breath:
    /// photo file deletion is fire-and-forget, so a hike deleted moments
    /// before the app was killed leaves its pictures on disk with nothing
    /// pointing at them and no screen that could ever show them again.
    ///
    /// A fetch that fails sweeps nothing rather than sweeping with an empty
    /// claim set — the same rule the tile trim follows, and for the same
    /// reason: an under-reported claim would delete every photo in the app.
    ///
    /// Nothing has to be reserved for sync any more. The engine used to hold
    /// pixels for a photo whose hike had not arrived yet, which looked exactly
    /// like an orphan; mirroring writes a photo's metadata and its hike in the
    /// same transaction, so a claimed file and its claim appear together.
    func reclaimOrphanedPhotos(
        in modelContext: ModelContext,
        store: HikePhotoStore = .shared
    ) {
        Self.reclaimOrphanedPhotos(from: store) {
            try modelContext.fetch(FetchDescriptor<Hike>())
        }
    }

    /// The rule itself, with the store and the fetch handed in — the companion
    /// seam to ``trimTileCache(_:limit:fetchingHikes:)`` and there for the
    /// same reason.
    ///
    /// The sweep itself is handed back, and `nil` *is* the refusal: a claim
    /// fetch that failed never reaches the store, so there is no task to
    /// return. The tile side needs no equivalent because
    /// ``TileCache/scheduleMaintenance(_:)`` is a single serial queue, where a
    /// later block starting is already proof that an earlier one finished. Two
    /// unstructured tasks have no order at all, so a caller that must know
    /// this sweep is done — today only the test that proves the refusal
    /// deletes nothing — has nothing else to wait on.
    @discardableResult static func reclaimOrphanedPhotos(
        from store: HikePhotoStore,
        fetchingHikes fetch: () throws -> [Hike]
    ) -> Task<Void, Never>? {
        guard let claimed = try? photoClaims(fetchingHikes: fetch) else { return nil }
        return Task(priority: .utility) {
            await reclaim(claimed, in: store)
        }
    }

    @concurrent
    private static func reclaim(_ claimed: Set<String>, in store: HikePhotoStore) async {
        store.reclaimOrphans(claimedBy: claimed)
    }
}

// MARK: - The walk left open

extension OpenHikesModel {
    /// What a launch found in the sidecar about a walk under way.
    enum OpenWalkAtLaunch: Equatable {
        /// Nothing was open.
        case absent
        /// The sidecar could not be read. Closes nothing, the way a failed
        /// claim fetch trims no tile: a walk that cannot be seen is not a
        /// walk that is over.
        case unreadable
        /// A walk recent enough to still be the walker's, to adopt.
        case resume(HikeLocalState, TrailWalkRecord)
        /// A walk older than ``TrailWalkPolicy/staleAtLaunchAfter``, to close
        /// as abandoned — kept if it covered enough, with no lingering panel.
        case abandon(HikeLocalState, TrailWalkRecord)
    }

    /// The rule itself, closure-driven and `static` for the reason the two
    /// sweeps above are: the branch that matters is the failing one, and
    /// nothing makes a `ModelContext` throw on demand.
    ///
    /// The whole sidecar is scanned rather than queried, because the column
    /// is a `Codable` value and an in-memory filter over rows that number one
    /// per hike with tiles is cheaper than a predicate SwiftData might not
    /// honour. One open walk at a time is the rule; if two are ever found,
    /// the newest is the one taken and the rest are left for the next sweep.
    static func openWalkAtLaunch(
        now: Date,
        fetchingLocalStates fetch: () throws -> [HikeLocalState]
    ) -> OpenWalkAtLaunch {
        guard let states = try? fetch() else { return .unreadable }
        let open = states
            .compactMap { state in state.walkInProgress.map { (state, $0) } }
            .max { $0.1.startedAt < $1.1.startedAt }
        guard let (state, record) = open else { return .absent }
        return record.isStale(at: now) ? .abandon(state, record) : .resume(state, record)
    }
}
