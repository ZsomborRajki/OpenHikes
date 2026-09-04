//
//  OfflineTileDownloader+Completion.swift
//  OpenHikes
//
//  What a finished run amounts to: the record its coverage is described by —
//  the thing a hike then claims — and what is said when no hike could.
//
//  Kept beside ``OfflineTileDownloader/finalize(savedKeys:tiles:source:generation:)``
//  rather than inside it because the shape of a record is a rule about
//  storage accounting, not about a download: a complete run lists no keys at
//  all — `storedTileKeys(route:offlineDownloads:)` re-derives them from the
//  route, and that reproducibility is what the whole design rests on — while
//  a partial run can only be described by the keys it actually verified on
//  disk. A run that saved nothing describes nothing, and a claim for it would
//  be a manifest entry pointing at no bytes.
//

import Foundation

extension OfflineTileDownloader {
    /// The coverage a run ended with, or `nil` when it saved nothing.
    ///
    /// - Parameter savedKeys: Keys verified as written to durable storage.
    /// - Parameter plannedCount: How many tiles the run set out to save;
    ///   equal to `savedKeys.count` exactly when the run was complete.
    nonisolated static func coverage(
        savedKeys: [String],
        plannedCount: Int,
        source: ActiveTileSource
    ) -> OfflineDownloadRecord? {
        if savedKeys.count == plannedCount {
            return OfflineDownloadRecord(
                providerID: source.providerID,
                maxZoom: source.maximumZ
            )
        }
        guard !savedKeys.isEmpty else { return nil }
        return OfflineDownloadRecord(
            providerID: source.providerID,
            maxZoom: source.maximumZ,
            savedTileKeys: savedKeys
        )
    }

    /// Said when the tiles landed but the hike they belong to could not be
    /// updated. Deliberately not a count of what was saved: those tiles are
    /// spoken for by nobody, so what the walker has is a download to run
    /// again rather than a map to finish.
    static let unclaimedMessage =
        "Downloaded the map, but couldn't record it for this hike. Try again."
}
