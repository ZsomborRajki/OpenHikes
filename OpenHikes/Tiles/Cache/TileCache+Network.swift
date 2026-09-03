//
//  TileCache+Network.swift
//  OpenHikes
//
//  What the cache is allowed to put on the radio, and when.
//
//  Split out of ``TileCache`` because it is the one part of the cache that
//  answers to the *device* rather than to the map: reachability, whether the
//  connection is metered or in Low Data Mode, and whether the system has
//  asked the app to spend less. A tile the walker is looking at and a tile
//  the app guessed they would want next are the same fetch to everything
//  else in the pipeline, and very different fetches here.
//

import Foundation
import Network
import Synchronization

nonisolated extension TileCache {

    /// Tracks network conditions and notifies renderers whenever interactive
    /// fetching changes from blocked to allowed.
    ///
    /// `isExpensive` and `isConstrained` come from the same path update and
    /// cost nothing extra to record — the app simply never asked for them
    /// before, and so spent a hiker's cellular allowance and battery on tiles
    /// it had no instruction to fetch. Nothing about them is configurable:
    /// see ``TileNetworkPolicy``.
    func startMonitoringNetwork() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.applyPath(
                TileNetworkConditions(
                    isOnline: path.status == .satisfied,
                    isExpensive: path.isExpensive,
                    isConstrained: path.isConstrained
                )
            )
        }
        monitor.start(queue: DispatchQueue(label: "TileCache.network"))
    }

    /// Records conditions, notifying renderers when interactive fetching
    /// becomes allowed. Shared by the monitor and the test seams so leaving
    /// Low Data Mode and reconnecting cannot disagree about what unblocks a
    /// renderer.
    private func applyPath(_ next: TileNetworkConditions) {
        let old = conditions.withLock { previous in
            let old = previous
            previous = next
            return old
        }
        // Asked of the policy rather than compared field by field, so this
        // cannot drift from what `loadTile` will actually do. Power is passed
        // for the same reason and weighs nothing today: `.interactive` is
        // decided by `isOnline` and `isConstrained` alone. If that ever
        // changes, this edge will need a power observer too — a path update is
        // the only thing that reaches here, and Low Power Mode is not one.
        let power = readPower()
        let wasAllowed = TileNetworkPolicy.decide(.interactive, conditions: old, power: power).isAllowed
        let isAllowed = TileNetworkPolicy.decide(.interactive, conditions: next, power: power).isAllowed
        if isAllowed, !wasAllowed { notifyInteractiveFetchUnblocked() }
    }

    /// Whether a fetch for `purpose` may open a connection right now, and why
    /// not when it may not.
    func networkDecision(for purpose: TileFetchPurpose) -> TileNetworkDecision {
        TileNetworkPolicy.decide(
            purpose,
            conditions: networkConditions,
            power: readPower()
        )
    }

    #if DEBUG
    /// Test hook: drives the reachability transitions a cache built with
    /// `monitorsNetwork: false` never receives — including the notification
    /// renderers listen for to retry tiles once fetching is allowed again.
    func setReachable(_ reachable: Bool) {
        applyPath(TileNetworkConditions(isOnline: reachable))
    }

    /// Test hook: the metered/constrained conditions a simulator's network
    /// never reports, so the policy can be exercised without one.
    func setNetworkConditions(_ next: TileNetworkConditions) {
        applyPath(next)
    }

    /// Test hook: the bounds the memory tier was actually configured with,
    /// rather than the constants it was meant to be configured from.
    var memoryLimits: (count: Int, bytes: Int) {
        (memory.countLimit, memory.totalCostLimit)
    }
    #endif

    /// Registers an interactive-fetch listener; held weakly, so no explicit
    /// removal is required (though ``removeObserver(_:)`` is available).
    func addObserver(_ observer: TileCacheObserver) {
        observers.withLock { boxes in
            boxes.removeAll { $0.value == nil }
            boxes.append(WeakObserver(value: observer))
        }
    }

    func removeObserver(_ observer: TileCacheObserver) {
        observers.withLock { boxes in
            boxes.removeAll { $0.value == nil || $0.value === observer }
        }
    }

    func notifyInteractiveFetchUnblocked() {
        // Stale saved coverage stops answering from the memory tier here —
        // synchronously, before any listener is told. What a listener does with
        // this is redraw, and a redraw reads that tier first: entries admitted
        // while there was no way to refresh them would answer it, and the map
        // the walker just regained signal for would go on showing the ground it
        // was showing offline until they panned it.
        staleCoverageInvalidatedAt.withLock { $0 = Date() }
        // MKOverlayRenderer.setNeedsDisplay must run on the main thread and the
        // path handler fires on a background queue, so hop first and deliver
        // there. The list itself does not need the hop: `observers` is a
        // `Mutex`, and that — not this queue — is what makes `addObserver` and
        // `removeObserver` safe to call from wherever a renderer happens to be.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let live = observers.withLock { boxes -> [TileCacheObserver] in
                boxes.removeAll { $0.value == nil }
                return boxes.compactMap(\.value)
            }
            live.forEach { $0.tileCacheDidUnblockInteractiveFetches() }
        }
    }
}
