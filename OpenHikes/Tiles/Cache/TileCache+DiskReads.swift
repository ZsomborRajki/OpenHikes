//
//  TileCache+DiskReads.swift
//  OpenHikes
//
//  Which of the two disk tiers answers a load, and on what terms.
//
//  The split here is the difference between cache and coverage. A browsing
//  tile is only ever offered while it is current; a durable tile — a map the
//  hiker saved for a trip — is offered current if it can be, and stale if
//  that is all there is. The map is offered the stale copy first and has it
//  refreshed behind it (``TileCache/loadStoredTileResult(forKey:)``), because
//  the refresh can wait a long time for a slot and a server.
//  ``TileCache/loadTileResult(forKey:url:purpose:)`` serves it last, once a
//  refresh has been refused by policy or has failed outright. Either way it
//  exists because the phone that cannot refresh a tile is the phone that most
//  needs the one already on disk.
//

import Algorithms
import Foundation
import os

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

nonisolated extension TileCache {

    /// What this device holds for a key, before any request is considered.
    ///
    /// This and the two lookups below are internal rather than private only
    /// because the loads in `TileCache` ask them, and `private` in an
    /// extension is file-scoped.
    struct StoredTileLookup {
        /// The memory tier's tile, or a current one from disk — `.failed` if
        /// a deletion raced the read — and `nil` when neither has the tile.
        var answer: TileLoadResult?
        /// Whether a durable copy exists, current or not: the tier a
        /// refetched tile is written back to.
        var wasDurable = false
        /// Whether that copy is coverage past its age: what is drawn while
        /// the refresh waits, or if it cannot be made.
        var hasStaleCoverage = false
    }

    /// Memory, then disk (ephemeral, then durable), publishing a disk hit to
    /// memory. Every load in `TileCache` goes through here, so the one the
    /// map makes outside the gate cannot disagree with the one it makes
    /// under it.
    func lookUpStoredTile(forKey key: String, token: MutationToken) -> StoredTileLookup {
        if let cached = memoryImage(forKey: key) { return StoredTileLookup(answer: .loaded(cached)) }
        return lookUpDiskTile(forKey: key, token: token)
    }

    /// The disk half of ``lookUpStoredTile(forKey:token:)``, which the map's
    /// refresh asks on its own.
    func lookUpDiskTile(forKey key: String, token: MutationToken) -> StoredTileLookup {
        // Which tier holds this key, and whether the durable copy is coverage
        // that has gone stale. Read *before* the disk lookup, which deletes an
        // expired browsing file as it finds it: the answer decides where a
        // refetched tile is written back, and whether there is anything to
        // fall back on if it cannot be fetched at all.
        let durableStoredAt = storedModificationDate(for: filePaths(forKey: key).durable, in: .durable)
        var lookup = StoredTileLookup(
            wasDurable: durableStoredAt != nil,
            hasStaleCoverage: durableStoredAt.map { isExpired($0) } ?? false
        )

        // Stale coverage with a browsing-tier duplicate beside it: reconciled
        // here, because the lookup below cannot be trusted to meet it. It asks
        // the browsing tier first, and asking unlinks an expired browsing file
        // — so two copies left by an older build that are both past the TTL
        // would lose the newer one before either the launch sweep or a promote
        // reached them, and the older would be the copy drawn. Same rule as
        // those two paths apply; see ``adoptNewerCachedCopy(cached:durable:diskName:)``.
        if lookup.hasStaleCoverage { reconcileStaleDuplicate(forKey: key) }

        if let tile = freshDiskImage(forKey: key) {
            lookup.answer = publishDiskTile(tile, forKey: key, token: token) ? .loaded(tile.image) : .failed
        }
        return lookup
    }

    /// The tile as it sits on disk *and still current*, ephemeral tier first —
    /// it's the one a browsing fetch refreshes, and the two hold the same image.
    ///
    /// Freshness is asked of both tiers even though only the browsing one is
    /// deleted for age: a durable tile past its TTL is still on disk, and the
    /// point of not returning it here is that the load path gets a chance to
    /// refresh it before falling back to it. ``durableImage(forKey:)`` is that
    /// fallback.
    func freshDiskImage(forKey key: String) -> (image: TileImage, storedAt: Date)? {
        let name = diskName(for: key)
        return [StorageTier.browsing, .durable].firstNonNil { tier in
            let file = directory(for: tier).appendingPathComponent(name)
            guard let storedAt = storedModificationDate(for: file, in: tier),
                  !isExpired(storedAt),
                  let image = decodedTile(at: file)
            else { return nil }
            return (image, storedAt)
        }
    }

    /// The durable tile for `key` whatever its age — the saved coverage a hike
    /// is claiming, read without asking whether it is current.
    ///
    /// Read only where the stale copy is about to be drawn: by the map, ahead
    /// of its refresh, and by a load that has ruled a refresh out or seen it
    /// fail. That is why it is a second read rather than something
    /// ``freshDiskImage(forKey:)`` returns alongside. The map's refresh asks
    /// the disk only whether a current copy has landed while it waited, and
    /// has no use for the old bytes.
    func durableImage(forKey key: String) -> TileImage? {
        decodedTile(at: filePaths(forKey: key).durable)
    }

    /// The stale durable tile for `key`, for a load that draws it as it is:
    /// the map's, ahead of its refresh, or one that has run out of ways to
    /// refresh it. Returns `nil` only if the saved bytes turn out to be
    /// unreadable, or a deletion took them while they were read, in which case
    /// the caller reports its original outcome.
    ///
    /// **Published to the memory tier, marked as stale.** That is not an
    /// optimisation here, it is what makes the tile appear: `draw` paints only
    /// what ``memoryImage(forKey:referenceDate:)`` holds, so coverage that
    /// stayed out of it would be reported as loaded, redrawn, missed again, and
    /// loaded again — a draw/load loop per tile per pass, with nothing ever on
    /// screen. Marking the entry is what keeps that from becoming the opposite
    /// mistake: a stale entry answers for
    /// ``TileCache/staleCoverageRecheckInterval`` and is then evicted, so the
    /// next draw comes back down here and the refresh is attempted again
    /// rather than the first stale draw of a session standing for the rest of
    /// it.
    ///
    /// Written under the same mutation token as every other publish, so a
    /// deletion racing this load still wins.
    func staleCoverage(
        forKey key: String,
        reason: String,
        token: MutationToken
    ) -> TileImage? {
        guard let image = durableImage(forKey: key) else { return nil }
        guard publishStaleCoverage(image, forKey: key, token: token) else { return nil }
        #if DEBUG
        Self.logger.debug(
            "Served saved tile \(key, privacy: .public) past its TTL: \(reason, privacy: .public)"
        )
        #endif
        return image
    }

    /// What a load that will not open a connection returns: saved coverage
    /// where there is any, and `otherwise` where there is not.
    ///
    /// Both reasons a load withholds a request come through here — network
    /// policy, and a deadline a server named for itself in `Retry-After` — so
    /// `reason` is the one place either is named. It describes the refusal,
    /// not what the map managed to put on screen in spite of it: a tile that
    /// silently never loads is the hardest thing in this pipeline to debug,
    /// and a hiker browsing downloaded ground offline is served entirely from
    /// here.
    func withheldFetch(
        forKey key: String,
        reason: String,
        hasStaleCoverage: Bool,
        token: MutationToken,
        otherwise: TileLoadResult
    ) -> TileLoadResult {
        guard hasStaleCoverage,
              let stale = staleCoverage(forKey: key, reason: reason, token: token)
        else { return otherwise }
        return .loaded(stale)
    }

    private func decodedTile(at file: URL) -> TileImage? {
        do {
            let data = try Data(contentsOf: file)
            guard let image = TileImage(data: data) else {
                Self.logger.error(
                    "Cached tile could not be decoded at \(file.path, privacy: .public)"
                )
                return nil
            }
            return image
        } catch {
            logFileError(
                error,
                operation: "read cached tile",
                url: file
            )
            return nil
        }
    }
}
