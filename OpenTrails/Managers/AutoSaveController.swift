//
//  AutoSaveController.swift
//  OpenTrails
//
//  Owns which hike (if any) is currently auto-saving OSM tiles while the user
//  browses its map, and periodically drains newly-persisted tile keys from
//  ``AutoSaveTileStore`` into that hike's SwiftData-backed manifest.
//

import Foundation
import os

@MainActor
@Observable
final class AutoSaveController {
    private static let logger = Logger(subsystem: "OpenTrails", category: "AutoSaveTiles")

    /// Weakly held: kept alive by whoever else references the hike (the
    /// selected-hike state, the pushed detail view); this controller shouldn't
    /// be the thing keeping a deleted hike around.
    private weak var activeHike: Hike?
    /// Not UI state, so excluded from observation tracking. `nonisolated(unsafe)`:
    /// only ever written in `init`/`deinit`, and `Task` cancellation is
    /// thread-safe, so this is safe to touch from `deinit` (which, on a
    /// `@MainActor` class, runs nonisolated).
    @ObservationIgnored
    private nonisolated(unsafe) var drainTask: Task<Void, Never>?
    @ObservationIgnored
    private var isSuspended = false
    @ObservationIgnored
    private var hasDeferredSelectionChange = false
    private weak var deferredHike: Hike?

    init() {
        drainTask = Task { [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled else { break }
                self.flushPendingKeys()
            }
        }
    }

    deinit {
        drainTask?.cancel()
    }

    /// Called whenever the map's selected hike changes, so auto-save follows
    /// whatever is actually on screen.
    func hikeSelectionChanged(to hike: Hike?) {
        let eligibleHike = hike.flatMap {
            $0.autoSaveTilesEnabled && $0.pointCount > 1 ? $0 : nil
        }
        guard !isSuspended else {
            deferredHike = eligibleHike
            hasDeferredSelectionChange = true
            return
        }
        applySelection(eligibleHike)
    }

    /// Toggled from the hike detail view's Auto-Save control.
    func setEnabled(_ enabled: Bool, for hike: Hike) {
        hike.autoSaveTilesEnabled = enabled
        if isSuspended {
            deferredHike = enabled && hike.pointCount > 1 ? hike : nil
            hasDeferredSelectionChange = true
            return
        }
        if enabled, hike.pointCount > 1 {
            activate(hike)
        } else if activeHike?.id == hike.id {
            deactivate()
        }
    }

    func isCapReached(for hike: Hike) -> Bool {
        AutoSaveTileStore.shared.isCapReached(for: hike.id)
    }

    /// The hike auto-save is currently running for, if any.
    ///
    /// For callers that have to stop it briefly and then put it back exactly as
    /// it was — Settings' delete-all, which flushes through a deactivation
    /// before clearing the manifests it would otherwise write into.
    var currentHike: Hike? { activeHike }

    /// Stops background tile work from creating new ownership after the final
    /// lifecycle flush. Pending keys are acknowledged only after SwiftData
    /// confirms the manifest was persisted.
    func sceneWillResignActive(save: () throws -> Void) {
        isSuspended = true
        let store = AutoSaveTileStore.shared
        let hike = activeHike
        let newKeys = hike.map { store.suspendAndSnapshotPendingKeys(for: $0.id) } ?? []

        let previousCount = hike?.autoSavedTileKeys.count ?? 0
        hike?.autoSavedTileKeys.append(contentsOf: newKeys)
        do {
            try save()
            if let hike {
                store.acknowledgePendingKeys(newKeys, for: hike.id)
            }
        } catch {
            hike?.autoSavedTileKeys.removeSubrange(previousCount...)
            Self.logger.error("Could not persist auto-saved tile ownership: \(error.localizedDescription, privacy: .public)")
        }
    }

    func sceneDidBecomeActive() {
        isSuspended = false
        if hasDeferredSelectionChange {
            let hike = deferredHike
            deferredHike = nil
            hasDeferredSelectionChange = false
            applySelection(hike)
            return
        }
        guard let hike = activeHike else { return }
        AutoSaveTileStore.shared.resumePersisting(for: hike.id)
    }

    /// Called just before `hike` is deleted, so the delete that follows sees a
    /// complete manifest. Waiting for the selection change to propagate back
    /// through SwiftUI would leave the tiles saved in the last drain window on
    /// disk with nothing claiming them — and they're durable, so nothing would
    /// ever reclaim them.
    func hikeWillBeDeleted(_ hike: Hike) {
        guard activeHike?.id == hike.id else { return }
        deactivate(flushWhileSuspended: true)
    }

    private func applySelection(_ hike: Hike?) {
        guard let hike else {
            deactivate()
            return
        }
        activate(hike)
    }

    private func activate(_ hike: Hike) {
        // Hand the outgoing hike its tiles back first: `setActiveHike` replaces
        // the store's state wholesale, pending set included, and those tiles are
        // already on disk.
        flushPendingKeys()
        activeHike = hike
        AutoSaveTileStore.shared.setActiveHike(
            id: hike.id,
            route: hike.coordinates,
            knownKeys: Set(hike.autoSavedTileKeys),
            acceptsNewClaims: !isSuspended
        )
    }

    private func deactivate(flushWhileSuspended: Bool = false) {
        // Same reason as in `activate`: `clearActiveHike` drops the pending set,
        // which is the only record of the last couple of seconds' worth of saves.
        if flushWhileSuspended {
            flushPendingKeysIgnoringSuspension()
        } else {
            flushPendingKeys()
        }
        activeHike = nil
        AutoSaveTileStore.shared.clearActiveHike()
    }

    /// Folds tiles persisted since the last pass into the active hike's
    /// manifest. Runs on a timer, and must also be called directly before any
    /// code that reads manifests to decide which tiles are still spoken for:
    /// until this runs, the newest tiles exist on disk with nothing in
    /// SwiftData pointing at them, and `deactivate()` discards the in-memory
    /// record that would have found them.
    func flushPendingKeys() {
        guard !isSuspended else { return }
        flushPendingKeysIgnoringSuspension()
    }

    private func flushPendingKeysIgnoringSuspension() {
        guard let hike = activeHike else { return }
        let newKeys = AutoSaveTileStore.shared.drainPendingKeys(for: hike.id)
        guard !newKeys.isEmpty else { return }
        hike.autoSavedTileKeys.append(contentsOf: newKeys)
    }
}
