//
//  HikeDetailView+OfflineStorage.swift
//  OpenTrails
//
//  Offline tile storage helpers for HikeDetailView.
//

import SwiftData
import SwiftUI

extension HikeDetailView {
    // MARK: Offline storage

    /// Measures this hike's saved tiles off the main thread. Deliberately reads
    /// only plain, cheap properties here (array references, not `.coordinates`,
    /// which remaps the whole route) — everything expensive (tile-grid
    /// enumeration across every download record, the keys `Set` union, and the
    /// disk stat calls) happens inside the detached task. Auto-save manifest
    /// changes reach this through ``scheduleStoredBytesRefresh()`` so repeated
    /// two-second drains collapse into one trailing measurement.
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
        storedBytesMeasurementTask = Task {
            let bytes = await Task.detached {
                let coordinates = route.map(\.clCoordinate)
                let keys = Array(
                    Set(OfflineTileDownloader.storedTileKeys(
                        route: coordinates,
                        offlineDownloads: offlineDownloads
                    ))
                    .union(autoSavedTileKeys)
                )
                return TileCache.shared.bytes(forKeys: keys)
            }.value
            guard !Task.isCancelled,
                  generation == storedBytesMeasurementGeneration else {
                return
            }
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
    /// real CPU work, so it's done inside the detached task, mirroring
    /// ``refreshStoredBytes()``.
    func deleteStoredTiles() {
        // First, and before the manifest is read: switching auto-save off folds
        // in the tiles saved since the last drain. Reading the manifest ahead of
        // that would delete a snapshot taken up to two seconds ago and strand
        // everything saved since — durably, where nothing would reclaim it.
        let hikes: [Hike]
        do {
            hikes = try modelContext.fetch(FetchDescriptor<Hike>())
        } catch {
            storageDeletionFailed = true
            return
        }
        autoSave.setEnabled(false, for: hike)
        let deletionPlan = StoredTileDeletionPlan(removing: hike, among: hikes)
        hike.offlineDownloads.removeAll()
        hike.autoSavedTileKeys.removeAll()
        invalidateStoredBytesMeasurement()
        storedBytes = 0
        downloader.reset()
        Task.detached {
            let keys = deletionPlan.exclusiveTileKeys()
            guard !keys.isEmpty else {
                return
            }
            TileCache.shared.removeTiles(forKeys: Array(keys))
        }
    }

    @ViewBuilder var storedTilesRow: some View {
        if !hike.offlineDownloads.isEmpty || !hike.autoSavedTileKeys.isEmpty {
            HStack {
                Label(
                    storedBytes.map { "Offline tiles · \(Self.byteText($0))" } ?? "Offline tiles",
                    systemImage: "internaldrive"
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                Spacer()

                Button(role: .destructive, action: deleteStoredTiles) {
                    Text("Delete").font(.caption.weight(.medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    static func byteText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
