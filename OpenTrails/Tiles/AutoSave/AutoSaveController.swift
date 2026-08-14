//
//  AutoSaveController.swift
//  OpenTrails
//
//  Owns which hike (if any) is currently auto-saving OSM tiles while the user
//  browses its map, and periodically drains newly-persisted tile keys from
//  ``AutoSaveTileStore`` into that hike's SwiftData-backed manifest.
//

import CoreLocation
import Foundation
import os

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
    /// main-actor-isolated class, runs nonisolated).
    @ObservationIgnored nonisolated(unsafe) private var drainTask: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var activationTask: Task<Void, Never>?
    @ObservationIgnored private var isSuspended = false
    @ObservationIgnored private var hasDeferredSelectionChange = false
    @ObservationIgnored private var activationRevision: UInt64 = 0
    private weak var deferredHike: Hike?
    /// The tile store this controller drives. Injectable so a test drives one
    /// with its own active hike and its own tile directories rather than the
    /// process-wide singleton the app uses.
    @ObservationIgnored private let store: AutoSaveTileStore

    /// How long a burst of newly-saved tiles is allowed to gather before it is
    /// folded into the active hike's manifest.
    ///
    /// This is a coalescing window, not a poll: the task waits on
    /// ``AutoSaveTileStore/pendingKeySignals()`` and only sleeps once it has
    /// been told there is something to fold. Drawing a screenful of tiles
    /// therefore costs one wake-up rather than one per tile, and an app
    /// sitting in the foreground with nothing being saved — no hike selected,
    /// auto-save off, the map not moving — costs none at all. It used to wake
    /// every two seconds regardless, for as long as the app was frontmost.
    ///
    /// Injectable, and `nil` disables the drain entirely, because a suite that
    /// asserts on *when* a key moves from the store to the manifest — the
    /// suspension-rollback tests — otherwise races it. Under a parallel run
    /// those tests can sit behind the main actor for longer than the window,
    /// at which point the drain folds the very keys the test is about to
    /// inspect. Tests that want the fold call ``flushPendingKeys()`` directly.
    init(store: AutoSaveTileStore = .shared, drainInterval: Duration? = .seconds(2)) {
        self.store = store
        guard let drainInterval else { return }
        drainTask = Task { [weak self, store] in
            for await _ in store.pendingKeySignals() {
                try? await Task.sleep(for: drainInterval)
                guard let self, !Task.isCancelled else { break }
                flushPendingKeys()
            }
        }
    }

    deinit {
        drainTask?.cancel()
        activationTask?.cancel()
    }

    /// Called whenever the map's selected hike changes, so auto-save follows
    /// whatever is actually on screen.
    func hikeSelectionChanged(to hike: Hike?) {
        let eligibleHike = hike.flatMap { candidateHike in
            candidateHike.autoSaveTilesEnabled && candidateHike.pointCount > 1 ? candidateHike : nil
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
        store.isCapReached(for: hike.id)
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
            Self.logger.error(
                "Could not persist auto-saved tile ownership: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func sceneDidBecomeActive() {
        isSuspended = false
        if hasDeferredSelectionChange {
            let hike = deferredHike
            deferredHike = nil
            hasDeferredSelectionChange = false
            applySelection(hike)
        } else if let hike = activeHike {
            store.resumePersisting(for: hike.id)
        }
        // The drain is signal-driven, and nothing signals while the scene is
        // inactive — so anything `sceneWillResignActive` couldn't acknowledge
        // is folded in here rather than waiting for the next tile to be drawn.
        flushPendingKeys()
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
        // Re-selecting the hike that is already active must not rebuild its
        // corridor — `beginActiveHike` installs an empty one, which would stop
        // claims until the rebuild lands. It does still have to put the store
        // back into an accepting state: a selection deferred while the scene
        // was inactive resolves through here, and `sceneWillResignActive` left
        // the store suspended.
        guard activeHike?.id != hike.id else {
            if !isSuspended {
                store.resumePersisting(for: hike.id)
            }
            return
        }
        // Hand the outgoing hike its tiles back first: `beginActiveHike`
        // replaces the store's state wholesale, pending set included, and those
        // tiles are already on disk.
        flushPendingKeys()
        cancelPendingActivation()
        activeHike = hike
        let hikeID = hike.id
        let route = hike.route
        store.beginActiveHike(
            id: hike.id,
            knownKeys: Set(hike.autoSavedTileKeys),
            acceptsNewClaims: !isSuspended
        )
        activationRevision &+= 1
        let revision = activationRevision
        activationTask = Task(priority: .utility) { [weak self] in
            guard let corridor = try? await Self.preparedCorridor(for: route) else {
                return
            }
            guard let self,
                  !Task.isCancelled,
                  activationRevision == revision,
                  activeHike?.id == hikeID else {
                return
            }
            store.updateCorridor(corridor, for: hikeID)
            activationTask = nil
        }
    }

    /// Converts the persisted route and builds its corridor on the concurrent
    /// executor. `@concurrent` keeps this inside `activationTask`, so
    /// ``cancelPendingActivation()`` stops it without a detached worker.
    @concurrent nonisolated
    private static func preparedCorridor(
        for route: [RouteCoordinate]
    ) async throws(CancellationError) -> TileCorridor {
        assertOffMainThread(
            "Auto-save route preparation must stay off the main thread"
        )
        var coordinates: [CLLocationCoordinate2D] = []
        coordinates.reserveCapacity(route.count)
        for (index, point) in route.enumerated() {
            if index.isMultiple(of: 255), Task.isCancelled {
                throw CancellationError()
            }
            coordinates.append(point.clCoordinate)
        }
        guard !Task.isCancelled else {
            throw CancellationError()
        }
        return TileCorridor(
            route: coordinates,
            bufferMeters: AutoSaveTileStore.corridorBufferMeters
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
        cancelPendingActivation()
        activeHike = nil
        store.clearActiveHike()
    }

    private func cancelPendingActivation() {
        activationRevision &+= 1
        activationTask?.cancel()
        activationTask = nil
    }

    /// Test/support hook that waits for the selected hike's corridor to finish
    /// preparing without polling or sleeping.
    func waitForActivation() async {
        await activationTask?.value
    }

    /// Folds tiles persisted since the last pass into the active hike's
    /// manifest. Runs from the controller's signal-driven drain, and must also
    /// be called directly before any code that reads manifests to decide which
    /// tiles are still spoken for: until this runs, the newest tiles exist on
    /// disk with nothing in SwiftData pointing at them, and `deactivate()`
    /// discards the in-memory record that would have found them.
    func flushPendingKeys() {
        guard !isSuspended else { return }
        flushPendingKeysIgnoringSuspension()
    }

    private func flushPendingKeysIgnoringSuspension() {
        guard let hike = activeHike else { return }
        let newKeys = store.drainPendingKeys(for: hike.id)
        guard !newKeys.isEmpty else { return }
        hike.autoSavedTileKeys.append(contentsOf: newKeys)
    }
}
