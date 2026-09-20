//
//  HikeDetailView+OfflineStorage.swift
//  OpenHikes
//
//  Offline tile storage helpers for HikeDetailView.
//

import CoreLocation
import SwiftData
import SwiftUI

nonisolated enum OfflineStorageMeasurement {
    /// `@concurrent` keeps this in the caller's task, so cancelling the
    /// measurement task in ``HikeDetailView/invalidateStoredBytesMeasurement()``
    /// propagates straight into the loops below — no detached worker, no
    /// hand-written cancellation handler — while the scan still runs on the
    /// concurrent executor.
    @concurrent
    static func measure(
        route: [RouteCoordinate],
        offlineDownloads: [OfflineDownloadRecord],
        autoSavedTileKeys: [String],
        cache: TileCache
    ) async throws(CancellationError) -> Int64 {
        assertOffMainThread(
            "Offline-storage measurement must stay off the main thread"
        )
        var coordinates: [CLLocationCoordinate2D] = []
        coordinates.reserveCapacity(route.count)
        for (index, point) in route.enumerated() {
            if index.isMultiple(of: 255), Task.isCancelled { throw CancellationError() }
            coordinates.append(point.clCoordinate)
        }
        let downloadedKeys = try OfflineTileDownloader.storedTileKeys(
            route: coordinates,
            offlineDownloads: offlineDownloads
        )
        guard !Task.isCancelled else { throw CancellationError() }
        let keys = Array(Set(downloadedKeys).union(autoSavedTileKeys))
        return try cache.bytes(forKeys: keys)
    }
}

extension HikeDetailView {
    // MARK: Offline storage

    /// Measures this hike's saved tiles off the main thread. Deliberately reads
    /// only plain, cheap properties here (array references, not `.coordinates`,
    /// which remaps the whole route) — everything expensive (tile-grid
    /// enumeration across every download record, the keys `Set` union, and the
    /// disk stat calls) happens inside ``OfflineStorageMeasurement``, which
    /// runs on the concurrent executor. Auto-save manifest changes reach this
    /// through ``scheduleStoredBytesRefresh()`` so a run of drains collapses
    /// into one trailing measurement.
    func refreshStoredBytes() {
        invalidateStoredBytesMeasurement()
        let route = hike.route
        let offlineDownloads = hike.offlineDownloads
        let autoSavedTileKeys = hike.autoSavedTileKeys
        guard !offlineDownloads.isEmpty || !autoSavedTileKeys.isEmpty else {
            storedBytes = 0
            return
        }
        let generation = storedBytesMeasurementGeneration
        storedBytesMeasurementTask = Task(priority: .utility) {
            let bytes: Int64
            do throws(CancellationError) {
                bytes = try await OfflineStorageMeasurement.measure(
                    route: route,
                    offlineDownloads: offlineDownloads,
                    autoSavedTileKeys: autoSavedTileKeys,
                    cache: .shared
                )
            } catch {
                return
            }
            guard !Task.isCancelled,
                  generation == storedBytesMeasurementGeneration else { return }
            storedBytes = bytes
        }
    }

    /// Where a download's verified coverage is recorded, bound to *this* hike
    /// at the moment the download starts.
    ///
    /// The hike is captured rather than read back off the screen when the run
    /// ends, because by then there may be no screen: dismissing this view
    /// cancels nothing, so the run goes on writing durable tiles with its
    /// `onChange` observer gone. One `HikeDetailView` can also outlive the
    /// hike it was first drawn for, and coverage merged into whichever hike
    /// the view is showing when the last tile lands is coverage claimed by
    /// the wrong trail.
    var offlineDownloadClaim: OfflineTileDownloader.Claim {
        let target = hike
        return { record in try OfflineDownloadClaim.commit(record, for: target) }
    }

    func scheduleStoredBytesRefresh() {
        guard !hike.offlineDownloads.isEmpty || !hike.autoSavedTileKeys.isEmpty else {
            invalidateStoredBytesMeasurement()
            storedBytes = 0
            return
        }
        storedBytesRefreshes.continuation.yield(storedBytesMeasurementGeneration)
    }

    func invalidateStoredBytesMeasurement() {
        storedBytesMeasurementTask?.cancel()
        storedBytesMeasurementTask = nil
        storedBytesMeasurementGeneration &+= 1
    }

    /// Forgets this hike's downloads and auto-saved tiles, and deletes them
    /// from disk once the store has accepted that it has.
    ///
    /// The order — and putting everything back when the commit is refused —
    /// is ``StoredTileDeletion``'s. What is left here is the screen: the byte
    /// row, the measurement behind it, and the alert.
    func deleteStoredTiles() {
        switch StoredTileDeletion.delete(
            storedTilesOf: hike,
            autoSave: autoSave,
            fetchingHikes: { try modelContext.fetch(FetchDescriptor<Hike>()) }
        ) {
        case let .committed(deletionPlan):
            // Only now the coverage is really gone: a refusal has to leave the
            // row describing the map the hike still has.
            //
            // The runs still in flight were stood down by the deletion, which
            // reaches all of them; this is the button on *this* screen, whose
            // last run may have finished long ago and still be saying so. A
            // download's result is not a result any more once the map it
            // produced has been deleted.
            downloader.cancel()
            invalidateStoredBytesMeasurement()
            storedBytes = 0
            // The key computation (tile-grid enumeration per download record)
            // is real CPU work, so it happens inside the plan's `@concurrent`
            // removal rather than here, mirroring ``refreshStoredBytes()``.
            Task(priority: .utility) {
                await deletionPlan.removeExclusiveTiles(from: .shared)
            }
        case let .refused(failure):
            storageDeletionFailure = failure
        }
    }

}
