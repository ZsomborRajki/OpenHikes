//
//  OfflineTileDownloader+Quota.swift
//  OpenHikes
//
//  What a bulk download does about a provider whose terms cap how much may be
//  kept on the device — today Stadia's 100 MB, see
//  ``TileProvider/durableByteLimit``.
//
//  A capped provider changes a download in three places, and all three are
//  here. Its budget is clamped, so a plan never asks for more than the ceiling
//  could hold. Its plan is measured against the space left before anything is
//  fetched, so a download that cannot fit stops and asks instead of half
//  finishing. And its failure message says which of the two things went wrong,
//  because "try again" is useless advice to someone who is out of allowance.
//

import Foundation

@MainActor
extension OfflineTileDownloader {
    /// The budget for one provider, which is ``tileBudget`` unless the
    /// provider's durable ceiling could not hold that many tiles.
    ///
    /// Stadia's 100 MB works out to roughly 3,400 tiles, fewer than the
    /// standard budget — so without this clamp a full download would plan more
    /// than the terms could ever let it save, and every run would end
    /// "Saved 3,413 of 4,000" no matter how much space had been freed.
    ///
    /// A pure function of the provider, because it has to be: `tileKeys` below
    /// recomputes a completed download's key set from scratch, and a budget
    /// that did not agree with the one used to fetch would recompute a
    /// different set than the one on disk.
    nonisolated static func tileBudget(forProviderID providerID: String) -> Int {
        guard let limit = TileCache.durableByteLimit(forProviderID: providerID) else {
            return tileBudget
        }
        return min(tileBudget, Int(limit / TileCache.estimatedTileBytes))
    }
    /// What a capped provider's ceiling is short by, and what it would cost to
    /// make room. Carries the numbers the confirmation has to name: deleting a
    /// hike's saved map is not something to ask about in the abstract.
    struct SpaceShortfall: Equatable, Sendable {
        let providerName: String
        /// Bytes to free from *other* saved maps for this download to fit.
        let bytesToFree: Int64
        /// The provider's device-wide ceiling, quoted so the message can
        /// explain that this is a licence term rather than a full disk.
        let limit: Int64
    }

    /// The durable-quota operations a download needs, injected for the same
    /// reason the transport is: a suite drives a ceiling of a few kilobytes
    /// rather than the app's hundred megabytes, against its own cache.
    struct QuotaBroker: Sendable {
        /// `nil` for a provider whose terms set no ceiling.
        var space: @Sendable (String) async -> (limit: Int64, used: Int64)?
        var reclaimable: @Sendable (String, Set<String>) async -> Int64
        var reclaim: @Sendable (String, Set<String>, Int64) async -> Int64

        static let live = Self(
            space: { providerID in
                await Self.offMain { TileCache.shared.durableSpace(forProviderID: providerID) }
            },
            reclaimable: { providerID, protected in
                await Self.offMain {
                    TileCache.shared.reclaimableDurableBytes(
                        forProviderID: providerID,
                        protecting: protected
                    )
                }
            },
            reclaim: { providerID, protected, bytes in
                await Self.offMain {
                    TileCache.shared.reclaimDurableBytes(
                        forProviderID: providerID,
                        protecting: protected,
                        byteCount: bytes
                    )
                }
            }
        )

        /// Every provider uncapped and nothing reclaimable, so a download is
        /// never asked to make room. What both unit-test bundles get: they are
        /// hosted by the app, and ``live`` reads `TileCache.shared` — the host
        /// app's own tile store, which no suite may touch. A suite that is
        /// testing the quota builds its own broker over its own
        /// ``TileSandbox``.
        static let unlimited = Self(
            space: { _ in nil },
            reclaimable: { _, _ in 0 },
            reclaim: { _, _, _ in 0 }
        )

        /// What ``OfflineTileDownloader`` takes when nothing is injected.
        static var standard: Self {
            AppLaunchEnvironment.isRunningTests ? .unlimited : .live
        }

        /// Each of these enumerates the durable tile directory, which the cache
        /// asserts must not happen on the main thread.
        @concurrent
        private static func offMain<T: Sendable>(_ body: @Sendable () -> T) async -> T {
            body()
        }
    }

    /// What this download is short by, or `nil` when it fits — which is always,
    /// for a provider whose terms set no ceiling.
    ///
    /// Sized from ``TileCache/estimatedTileBytes`` rather than from the tiles
    /// themselves, which have not been fetched yet. The estimate only decides
    /// *whether to ask*; the per-tile reservation on the write path is what
    /// actually holds the line, so an estimate that runs high frees a little
    /// more than was needed rather than overrunning the limit.
    func spaceShortfall(
        tiles: [Tile],
        source: ActiveTileSource
    ) async -> SpaceShortfall? {
        guard let space = await quota.space(source.providerID) else { return nil }
        let required = Int64(tiles.count) * TileCache.estimatedTileBytes
        let available = max(0, space.limit - space.used)
        guard required > available else { return nil }

        // This download's own tiles are never candidates: re-saving a hike
        // must not evict the copy of it already on disk.
        let plannedKeys = Set(tiles.map { $0.cacheKey(providerID: source.providerID) })
        let reclaimable = await quota.reclaimable(source.providerID, plannedKeys)
        let shortfall = min(required - available, reclaimable)
        guard shortfall > 0 else { return nil }

        return SpaceShortfall(
            providerName: TileProvider.provider(id: source.providerID).name,
            bytesToFree: shortfall,
            limit: space.limit
        )
    }

    /// The shortfall a download is waiting on, when it is waiting.
    /// Lets a view drive its confirmation off one optional rather than
    /// re-matching the phase.
    var pendingSpaceShortfall: SpaceShortfall? {
        guard case .needsSpace(let shortfall) = phase else { return nil }
        return shortfall
    }

    /// Why a partial download stopped, in the user's terms.
    ///
    /// Worth the extra directory walk on a path that only runs once, at the
    /// end of a failed download: the generic messages tell a user to "try
    /// again", and for a provider that has hit its licensed ceiling, trying
    /// again is the one thing that cannot possibly work.
    func failureMessage(
        savedCount: Int,
        plannedCount: Int,
        source: ActiveTileSource
    ) async -> String {
        if let space = await quota.space(source.providerID),
           space.used >= space.limit {
            let name = TileProvider.provider(id: source.providerID).name
            let limit = ByteCountFormatter.string(fromByteCount: space.limit, countStyle: .file)
            return savedCount == 0
                ? "\(name) maps are full. Its licence allows \(limit) of saved tiles on this device — "
                    + "delete another saved map to make room."
                : "Saved \(savedCount) of \(plannedCount) tiles, then reached the \(limit) "
                    + "\(name) allows on this device. Delete another saved map to make room."
        }
        return savedCount == 0
            ? "Couldn't save any tiles. Check your connection and try again."
            : "Saved \(savedCount) of \(plannedCount) tiles. Try again to finish the download."
    }

}
