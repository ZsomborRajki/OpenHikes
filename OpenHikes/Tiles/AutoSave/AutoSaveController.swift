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
import OpenHikesData
import os

@Observable
final class AutoSaveController {
    private static let logger = Logger(subsystem: "OpenHikes", category: "AutoSaveTiles")

    /// Weakly held: kept alive by whoever else references the hike (the
    /// selected-hike state, the pushed detail view); this controller shouldn't
    /// be the thing keeping a deleted hike around.
    private weak var activeHike: Hike?
    /// The read of the line ``activeHike``'s corridor was last asked for.
    /// Edit Route saves into the same hike, so its ID alone cannot tell a
    /// re-selection from a new route — the same reason `HikeDetailRouteKey`
    /// holds the route itself. ``SelectedLine`` hands out the same read for
    /// as long as nothing has written the line, so the same one again is a
    /// re-selection; a new one is compared — see ``activate(_:)``.
    @ObservationIgnored private var activeLine: SelectedLine.Read?
    /// The read whose line the store's corridor was built from, so a new
    /// read that holds the same line keeps the corridor. `nil` until the
    /// hike's first corridor lands.
    @ObservationIgnored private var corridorLine: SelectedLine.Read?
    /// The watch on ``activeHike``'s line, so a line written under it is
    /// followed without the hike being announced again.
    @ObservationIgnored private var lineWrite: SelectedLine.Write?
    /// Where a hike's line is read — off the main actor, and once for this
    /// and the other readers the selection hands it to.
    @ObservationIgnored private let lines: SelectedLine
    /// Not UI state, so excluded from observation tracking. Ordinary isolated
    /// storage: the `isolated deinit` below is what cancels them, and SE-0371
    /// hops that deinit back to the main actor before it runs, so these are
    /// only ever touched from the actor that wrote them — the same choice
    /// ``PowerStateMonitor`` and ``MovementReminderController`` make, and what
    /// removed the `nonisolated(unsafe)` this used to need.
    @ObservationIgnored private var drainTask: Task<Void, Never>?
    @ObservationIgnored private var activationTask: Task<Void, Never>?
    @ObservationIgnored private var isSuspended = false
    @ObservationIgnored private var hasDeferredSelectionChange = false
    @ObservationIgnored private var activationRevision: UInt64 = 0
    private weak var deferredHike: Hike?
    /// The tile store this controller drives. Injectable so a test drives one
    /// with its own active hike and its own tile directories rather than the
    /// process-wide singleton the app uses.
    @ObservationIgnored private let store: AutoSaveTileStore
    /// Whether the map draws raster tiles at all — the selected map's own, or
    /// the hiking-route layer's over it.
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
        lines: SelectedLine = SelectedLine(),
        mapRendersTiles: @escaping () -> Bool = { true }
    ) {
        self.store = store
        self.lines = lines
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

    /// Cancelling the drain is what ends its wait on
    /// ``AutoSaveTileStore/pendingKeySignals()``; without it the task stays
    /// suspended on that iterator for the life of the store, with no hike left
    /// to fold anything into.
    ///
    /// SE-0371 makes a *final release taken off the main actor* schedule this
    /// rather than run it, so cancellation is only synchronous when the
    /// controller is dropped on the main actor — which is where it is created,
    /// selected from and released. Nothing depends on the difference: both
    /// tasks hold `self` weakly and re-check it after every suspension, so a
    /// deinit that has not run yet still cannot let a pending activation
    /// publish a corridor or a drain fold a key. `AutoSaveTaskLifecycleTests` pins
    /// both halves.
    isolated deinit {
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

    /// Whether `hike` should be auto-saving right now: it has to want to, and
    /// be drawn on a map that fetches tiles.
    ///
    /// It also needs a route worth a corridor, but that is asked once the
    /// line is read rather than here: counting the points reads `route`, and
    /// on the main actor that decodes the whole of it (#1232). Until then the
    /// store has the empty corridor ``AutoSaveTileStore/beginActiveHike(id:knownKeys:acceptsNewClaims:)``
    /// starts with, which claims nothing, and a line of one point or none
    /// stands the hike down — see ``prepareCorridor(for:line:)``.
    private func isEligible(_ hike: Hike) -> Bool {
        hike.autoSaveTilesEnabled && mapRendersTiles()
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
    /// ``AutoSaveTileStore``'s pending set into the hike's manifest, so
    /// whatever returns the manifest to what it held before the fold takes
    /// them back out with it, and the store no longer has them either.
    struct StandDown {
        let hikeID: UUID
        let foldedKeys: [String]
    }

    /// Called just before something the store may refuse takes this hike's
    /// tiles away — the hike itself in ``HikeDeletion``, its saved map in
    /// ``StoredTileDeletion`` — so what follows sees a complete manifest.
    /// Waiting for the selection change to propagate back through SwiftUI
    /// would leave the tiles saved in the last drain window on disk with
    /// nothing claiming them — and they're durable, so nothing would ever
    /// reclaim them.
    ///
    /// - Returns: what ``restoreAfterRefusal(_:for:)`` needs to undo this,
    ///   or `nil` when this hike wasn't the one auto-saving and nothing stood
    ///   down. A deletion that can be refused has to hold on to it.
    func standDown(for hike: Hike) -> StandDown? {
        guard activeHike?.id == hike.id else { return nil }
        return StandDown(
            hikeID: hike.id,
            foldedKeys: deactivate(flushWhileSuspended: true)
        )
    }

    /// Puts auto-save back on a hike whose deletion the store would not
    /// accept — of the hike, or of the tiles it had saved.
    ///
    /// Both halves have to be undone. ``StoredTileDeletion`` puts back the
    /// manifest it read before the fold, so the keys folded in on the way out
    /// claim nothing — and their tiles are durable, so the next launch trim
    /// would delete a walk's worth of map the user still has the hike for.
    /// ``HikeDeletion`` commits the fold before it takes the hike out, so
    /// there they are still in it — committed, or pending where that commit
    /// was refused too — and only a key the manifest lacks is added. And the
    /// selection never changed, so nothing else is going to re-arm the
    /// controller: without this the still-selected hike would quietly stop
    /// auto-saving until it was selected again.
    func restoreAfterRefusal(_ standDown: StandDown, for hike: Hike) {
        guard standDown.hikeID == hike.id else { return }
        let held = Set(hike.autoSavedTileKeys)
        hike.autoSavedTileKeys.append(contentsOf: standDown.foldedKeys.filter { !held.contains($0) })
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
        let line = lines.read(of: hike)
        if activeHike?.id == hike.id {
            // Re-selecting the hike that is already active, with the line it
            // already has, must not rebuild its corridor: the build is
            // route-sized work for an answer the store already holds. It does
            // still have to put the store back into an accepting state: a
            // selection deferred while the scene was inactive resolves
            // through here, and `sceneWillResignActive` left the store
            // suspended.
            if !isSuspended {
                store.resumePersisting(for: hike.id)
            }
            guard line !== activeLine else { return }
            // A new read of the same hike's line, which may be an edited line
            // — its tiles stay its own, but the corridor has to follow it, or
            // it would refuse every tile around a section moved or added
            // outside the old bounds until the hike was selected again. It
            // need not be: a line can be written back as it was.
            // So the corridor up now stays up until the new line is compared
            // with the one it was built from, and an unchanged line keeps it.
            cancelPendingActivation()
        } else {
            // Hand the outgoing hike its tiles back first: `beginActiveHike`
            // replaces the store's state wholesale, pending set included, and
            // those tiles are already on disk.
            flushPendingKeys()
            cancelPendingActivation()
            activeHike = hike
            corridorLine = nil
            store.beginActiveHike(
                id: hike.id,
                knownKeys: Set(hike.autoSavedTileKeys),
                acceptsNewClaims: !isSuspended
            )
        }
        lineWrite = lines.watch(hike) { [weak self] write in self?.lineDidChange(write) }
        activeLine = line
        prepareCorridor(for: hike.id, line: line)
    }

    /// A line written under the active hike is announced as the hike again,
    /// which takes the new read, compares it and rebuilds the corridor only
    /// for a line that differs — and defers all of it while the scene is
    /// inactive, as any announcement is.
    ///
    /// Unless a selection is already waiting for the scene: that one replaces
    /// this hike when it is applied, and reads its own line then, so the hike
    /// being left is not put back in its place — the rule
    /// ``standDownShortLine()`` follows too.
    private func lineDidChange(_ write: SelectedLine.Write) {
        guard write === lineWrite, let hike = activeHike, !hasDeferredSelectionChange else { return }
        hikeSelectionChanged(to: hike)
    }

    /// What a corridor build came back with.
    nonisolated private enum PreparedCorridor: Sendable {
        case corridor(TileCorridor)
        /// The line the installed corridor was built from, read again.
        case unchanged
        /// One point or none: no corridor worth the name.
        case tooShort
    }

    /// Builds the corridor of `line` off the main actor once it is read and
    /// hands it to the store, unless a newer activation — another hike, or
    /// another edit of this one — has superseded it by the time it is ready.
    ///
    /// A line of one point or none has no corridor worth the name, so it
    /// stands the hike down instead: the toggle is disabled for one in the
    /// UI, and the empty corridor the store held meanwhile claimed nothing.
    private func prepareCorridor(for hikeID: UUID, line: SelectedLine.Read) {
        activationRevision &+= 1
        let revision = activationRevision
        let installed = corridorLine
        activationTask = Task(priority: .utility) { [weak self] in
            let prepared: PreparedCorridor
            do throws(CancellationError) {
                prepared = try await Self.preparedCorridor(for: line, unlessBuiltFrom: installed)
            } catch {
                return
            }
            guard let self,
                  !Task.isCancelled,
                  activationRevision == revision,
                  activeHike?.id == hikeID else { return }
            switch prepared {
            case .tooShort:
                standDownShortLine()
                return
            case .unchanged:
                break
            case let .corridor(corridor):
                store.updateCorridor(corridor, for: hikeID)
            }
            corridorLine = line
            activationTask = nil
        }
    }

    /// Lets go of a hike whose line turned out too short for a corridor, the
    /// way deselecting it would: at once, or when the scene is back if it is
    /// inactive — unless a selection made meanwhile is already waiting to
    /// replace this one, which it will.
    private func standDownShortLine() {
        guard isSuspended else {
            deactivate()
            return
        }
        guard !hasDeferredSelectionChange else { return }
        deferredHike = nil
        hasDeferredSelectionChange = true
    }

    /// Waits for the line, compares it with the one the installed corridor
    /// was built from, and otherwise converts it and builds its corridor, all
    /// on the concurrent executor: a long route is a long comparison as well
    /// as a long build. `@concurrent` keeps this inside `activationTask`, so
    /// ``cancelPendingActivation()`` stops it without a detached worker.
    @concurrent
    private static func preparedCorridor(
        for line: SelectedLine.Read,
        unlessBuiltFrom installed: SelectedLine.Read?
    ) async throws(CancellationError) -> PreparedCorridor {
        assertOffMainThread(
            "Auto-save route preparation must stay off the main thread"
        )
        let route = await line.route
        guard route.count > 1 else { return .tooShort }
        if let installed, await installed.route == route { return .unchanged }
        guard !Task.isCancelled else { throw CancellationError() }
        let coordinates = try route.clCoordinates()
        guard !Task.isCancelled else { throw CancellationError() }
        return .corridor(TileCorridor(
            route: coordinates,
            bufferMeters: AutoSaveTileStore.corridorBufferMeters
        ))
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
        activeLine = nil
        corridorLine = nil
        lineWrite = nil
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
