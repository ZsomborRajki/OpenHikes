//
//  AutoSaveController.swift
//  OpenHikes
//
//  Owns which hike (if any) is currently auto-saving map tiles while the user
//  browses its map, and folds newly-persisted tile keys from
//  ``AutoSaveTileStore`` into that hike's SwiftData-backed manifest as they
//  arrive.
//

import CoreLocation
import Foundation
import os

@Observable
final class AutoSaveController {
    private static let logger = Logger(subsystem: "OpenHikes", category: "AutoSaveTiles")

    /// Weakly held: kept alive by whoever else references the hike (the
    /// selected-hike state, the pushed detail view); this controller shouldn't
    /// be the thing keeping a deleted hike around.
    private weak var activeHike: Hike?
    /// Not UI state, so excluded from observation tracking. `nonisolated(unsafe)`
    /// so `deinit` — which runs nonisolated on a main-actor-isolated class — can
    /// cancel them; every write is on the main actor, and `Task` cancellation is
    /// itself thread-safe.
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
    /// Whether the selected map draws raster tiles at all.
    ///
    /// Auto-save is a promise about *drawn* tiles, so the code that arms it has
    /// to keep that promise rather than relying on the toggle being hidden.
    /// With the system base map selected nothing is ever fetched, so activating
    /// would buy a route-sized ``TileCorridor`` build and a live store entry
    /// for a hike that can never claim a tile — which is exactly the work that
    /// option exists to avoid.
    ///
    /// A closure, like ``OfflineTileDownloader``'s reachability, rather than a
    /// `UserDefaults` read: both unit-test bundles are hosted by the app, so a
    /// controller that looked the setting up itself would make every auto-save
    /// suite depend on the map the developer last picked. The default answers
    /// "tiles are drawn", which is what a test that never mentions a provider
    /// means.
    @ObservationIgnored private let mapRendersTiles: () -> Bool

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
    init(
        store: AutoSaveTileStore = .shared,
        drainInterval: Duration? = .seconds(2),
        mapRendersTiles: @escaping () -> Bool = { true }
    ) {
        self.store = store
        self.mapRendersTiles = mapRendersTiles
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

    /// Called whenever the map's selected hike changes — or whenever the
    /// selected map source changes — so auto-save follows whatever is actually
    /// being drawn on screen.
    func hikeSelectionChanged(to hike: Hike?) {
        let eligibleHike = hike.flatMap { candidateHike in
            isEligible(candidateHike) ? candidateHike : nil
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
        // The per-hike preference is recorded either way. Turning it on while
        // the system base map is selected is a stored intention, not a reason
        // to start saving tiles nothing is drawing.
        let shouldRun = enabled && isEligible(hike)
        if isSuspended {
            deferredHike = shouldRun ? hike : nil
            hasDeferredSelectionChange = true
            return
        }
        if shouldRun {
            activate(hike)
        } else if activeHike?.id == hike.id {
            deactivate()
        }
    }

    /// Whether `hike` should be auto-saving right now: it has to want to, have
    /// a route worth a corridor, and be drawn on a map that fetches tiles.
    private func isEligible(_ hike: Hike) -> Bool {
        hike.autoSaveTilesEnabled && hike.pointCount > 1 && mapRendersTiles()
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

    /// What it takes to put auto-save back after a deletion the store refused.
    ///
    /// The keys are the payload: they were moved out of
    /// ``AutoSaveTileStore``'s pending set into the hike's manifest as an
    /// *unsaved* write, so the rollback that returns the hike takes them back
    /// out again, and the store no longer has them either.
    struct StandDown {
        let hikeID: UUID
        let foldedKeys: [String]
    }

    /// Called just before `hike` is deleted, so the delete that follows sees a
    /// complete manifest. Waiting for the selection change to propagate back
    /// through SwiftUI would leave the tiles saved in the last drain window on
    /// disk with nothing claiming them — and they're durable, so nothing would
    /// ever reclaim them.
    ///
    /// - Returns: what ``hikeDeletionWasRefused(_:for:)`` needs to undo this,
    ///   or `nil` when this hike wasn't the one auto-saving and nothing stood
    ///   down. A deletion that can be refused has to hold on to it.
    func hikeWillBeDeleted(_ hike: Hike) -> StandDown? {
        guard activeHike?.id == hike.id else { return nil }
        return StandDown(
            hikeID: hike.id,
            foldedKeys: deactivate(flushWhileSuspended: true)
        )
    }

    /// Puts auto-save back on a hike whose deletion the store would not accept.
    ///
    /// Both halves have to be undone. The rollback returned the hike, but it
    /// returned its manifest to the last committed state with it, so the keys
    /// folded in on the way out claim nothing — and their tiles are durable,
    /// so the next launch trim would delete a walk's worth of map the user
    /// still has the hike for. And the selection never changed, so nothing
    /// else is going to re-arm the controller: without this the still-selected
    /// hike would quietly stop auto-saving until it was selected again.
    func hikeDeletionWasRefused(_ standDown: StandDown, for hike: Hike) {
        guard standDown.hikeID == hike.id else { return }
        hike.autoSavedTileKeys.append(contentsOf: standDown.foldedKeys)
        // The path a re-selection takes, so eligibility and a suspended scene
        // are answered here the way they are answered there.
        hikeSelectionChanged(to: hike)
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
            guard let corridor = try? await Self.preparedCorridor(for: route) else { return }
            guard let self,
                  !Task.isCancelled,
                  activationRevision == revision,
                  activeHike?.id == hikeID else { return }
            store.updateCorridor(corridor, for: hikeID)
            activationTask = nil
        }
    }

    /// Converts the persisted route and builds its corridor on the concurrent
    /// executor. `@concurrent` keeps this inside `activationTask`, so
    /// ``cancelPendingActivation()`` stops it without a detached worker.
    @concurrent
    private static func preparedCorridor(
        for route: [RouteCoordinate]
    ) async throws(CancellationError) -> TileCorridor {
        assertOffMainThread(
            "Auto-save route preparation must stay off the main thread"
        )
        var coordinates: [CLLocationCoordinate2D] = []
        coordinates.reserveCapacity(route.count)
        for (index, point) in route.enumerated() {
            if index.isMultiple(of: 255), Task.isCancelled { throw CancellationError() }
            coordinates.append(point.clCoordinate)
        }
        guard !Task.isCancelled else { throw CancellationError() }
        return TileCorridor(
            route: coordinates,
            bufferMeters: AutoSaveTileStore.corridorBufferMeters
        )
    }

    /// - Returns: the keys folded into the outgoing hike's manifest on the way
    ///   out, for the one caller that may have to hand them back.
    @discardableResult private func deactivate(flushWhileSuspended: Bool = false) -> [String] {
        // Same reason as in `activate`: `clearActiveHike` drops the pending set,
        // which is the only record of the last couple of seconds' worth of saves.
        let folded = flushWhileSuspended
            ? flushPendingKeysIgnoringSuspension()
            : flushPendingKeys()
        cancelPendingActivation()
        activeHike = nil
        store.clearActiveHike()
        return folded
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
    ///
    /// - Returns: what it folded, so a fold that has to be taken back — a
    ///   deletion the store then refused — can be.
    @discardableResult func flushPendingKeys() -> [String] {
        guard !isSuspended else { return [] }
        return flushPendingKeysIgnoringSuspension()
    }

    @discardableResult private func flushPendingKeysIgnoringSuspension() -> [String] {
        guard let hike = activeHike else { return [] }
        let newKeys = Array(store.drainPendingKeys(for: hike.id))
        guard !newKeys.isEmpty else { return [] }
        hike.autoSavedTileKeys.append(contentsOf: newKeys)
        return newKeys
    }
}
