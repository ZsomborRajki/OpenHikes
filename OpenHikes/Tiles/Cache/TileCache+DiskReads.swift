//
//  TileCache+DiskReads.swift
//  OpenHikes
//
//  Which of the two disk tiers answers a load, and on what terms.
//
//  The split here is the difference between cache and coverage. A browsing
//  tile is only ever offered while it is current; a durable tile — a map the
//  walker saved for a trip — is offered current if it can be, and stale if
//  that is all there is. Serving the stale copy is the last step of
//  ``TileCache/loadTileResult(forKey:url:purpose:)``, reached only once a
//  refresh has been refused by policy or has failed outright, and it exists
//  because the phone that cannot refresh a tile is the phone that most needs
//  the one already on disk.
//

import Foundation
import os

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

nonisolated extension TileCache {

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
        for tier in [StorageTier.browsing, .durable] {
            let file = directory(for: tier).appendingPathComponent(name)
            guard let storedAt = storedModificationDate(for: file, in: tier),
                  !isExpired(storedAt)
            else { continue }
            guard let image = decodedTile(at: file) else { continue }
            return (image, storedAt)
        }
        return nil
    }

    /// The durable tile for `key` whatever its age — the saved coverage a hike
    /// is claiming, read without asking whether it is current.
    ///
    /// Only reached once a refresh has been ruled out or has failed, which is
    /// why it is a second read rather than something ``freshDiskImage(forKey:)``
    /// returns alongside: on the ordinary path the refresh succeeds and these
    /// bytes are replaced, and decoding a tile that is about to be thrown away
    /// would put a wasted PNG decode on the render path for every stale tile on
    /// screen.
    func durableImage(forKey key: String) -> TileImage? {
        decodedTile(at: filePaths(forKey: key).durable)
    }

    /// The stale durable tile for `key`, for a load that has run out of ways to
    /// refresh it. Returns `nil` only if the saved bytes turn out to be
    /// unreadable, in which case the caller reports its original outcome.
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
        RenderSignpost.mark("TileServedStale", "key=\(key) reason=\(reason)")
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
    /// the `TileFetchSuppressed` signpost is emitted for either, *before*
    /// anything is drawn. The signpost describes the refusal, not what the map
    /// managed to put on screen in spite of it: a walker browsing downloaded
    /// ground offline would otherwise emit none at all, and a tile that
    /// silently never loads is the hardest thing in this pipeline to debug.
    func withheldFetch(
        forKey key: String,
        purpose: TileFetchPurpose,
        reason: String,
        hasStaleCoverage: Bool,
        token: MutationToken,
        otherwise: TileLoadResult
    ) -> TileLoadResult {
        RenderSignpost.mark(
            "TileFetchSuppressed",
            "purpose=\(purpose.rawValue) reason=\(reason)"
        )
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
