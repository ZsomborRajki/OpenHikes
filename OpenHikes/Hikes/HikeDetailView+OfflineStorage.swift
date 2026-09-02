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

    /// Forgets this hike's downloads and auto-saved tiles, and deletes them from
    /// disk. The key computation (tile-grid enumeration per download record) is
    /// real CPU work, so it happens inside ``StoredTileDeletionPlan``'s
    /// `@concurrent` removal rather than here, mirroring ``refreshStoredBytes()``.
    func deleteStoredTiles() {
        // Before the manifest is read: switching auto-save off folds in the
        // tiles saved since the last drain. Reading the manifest ahead of that
        // would delete a snapshot taken up to two seconds ago and strand
        // everything saved since — durably, where nothing would reclaim it.
        let hikes: [Hike]
        do {
            hikes = try modelContext.fetch(FetchDescriptor<Hike>())
        } catch {
            storageDeletionFailed = true
            return
        }
        autoSave.setEnabled(false, for: hike)
        // Before a single manifest is touched: a plan that cannot be built is
        // a claim set that is short by at least one hike, and emptying this
        // hike's manifest against it would either strip a neighbour's offline
        // map or — if this hike's own sidecar is the unreadable one — write
        // the removals through to a freshly materialised empty row, leaving
        // the real one behind still claiming everything.
        guard let deletionPlan = StoredTileDeletionPlan(removing: hike, among: hikes) else {
            storageDeletionFailed = true
            return
        }
        hike.offlineDownloads.removeAll()
        hike.autoSavedTileKeys.removeAll()
        invalidateStoredBytesMeasurement()
        storedBytes = 0
        downloader.reset()
        Task(priority: .utility) {
            await deletionPlan.removeExclusiveTiles(from: .shared)
        }
    }

}
