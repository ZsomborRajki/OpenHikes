//
//  AutoSaveController.swift
//  OpenTrails
//
//  Owns which hike (if any) is currently auto-saving OSM tiles while the user
//  browses its map, and periodically drains newly-persisted tile keys from
//  ``AutoSaveTileStore`` into that hike's SwiftData-backed manifest.
//

import Foundation

@MainActor
@Observable
final class AutoSaveController {
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
        guard let hike, hike.autoSaveTilesEnabled, hike.pointCount > 1 else {
            deactivate()
            return
        }
        activate(hike)
    }

    /// Toggled from the hike detail view's Auto-Save control.
    func setEnabled(_ enabled: Bool, for hike: Hike) {
        hike.autoSaveTilesEnabled = enabled
        if enabled, hike.pointCount > 1 {
            activate(hike)
        } else if activeHike?.id == hike.id {
            deactivate()
        }
    }

    func isCapReached(for hike: Hike) -> Bool {
        AutoSaveTileStore.shared.isCapReached(for: hike.id)
    }

    private func activate(_ hike: Hike) {
        activeHike = hike
        AutoSaveTileStore.shared.setActiveHike(
            id: hike.id,
            route: hike.coordinates,
            knownKeys: Set(hike.autoSavedTileKeys)
        )
    }

    private func deactivate() {
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
        guard let hike = activeHike else { return }
        let newKeys = AutoSaveTileStore.shared.drainPendingKeys(for: hike.id)
        guard !newKeys.isEmpty else { return }
        hike.autoSavedTileKeys.append(contentsOf: newKeys)
    }
}
