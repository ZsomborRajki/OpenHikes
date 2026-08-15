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

    /// Tracks reachability and, on each offline→online transition, notifies
    /// renderers so they clear failed tiles and try again.
    ///
    /// `isExpensive` and `isConstrained` come from the same path update and
    /// cost nothing extra to record — the app simply never asked for them
    /// before, and so spent a hiker's cellular allowance and battery on tiles
    /// it had no instruction to fetch.
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

    /// Records conditions, notifying renderers only on an offline→online
    /// edge. Shared by the monitor and by ``setReachable(_:)`` so the two
    /// can't disagree about what a reconnect is.
    private func applyPath(_ next: TileNetworkConditions) {
        let wasOnline = conditions.withLock { previous in
            let old = previous.isOnline
            previous = next
            return old
        }
        if next.isOnline, !wasOnline { notifyReconnect() }
    }

    /// Whether a fetch for `purpose` may open a connection right now, and why
    /// not when it may not.
    func networkDecision(for purpose: TileFetchPurpose) -> TileNetworkDecision {
        TileNetworkPolicy.decide(
            purpose,
            conditions: networkConditions,
            allowsCellular: cellularAllowed.withLock { $0 },
            power: readPower()
        )
    }

    /// Called by the settings screen when the cellular toggle moves. Pushed
    /// rather than observed so the cache does not have to wake for every
    /// unrelated `UserDefaults` change the app makes.
    func setAllowsCellularDownloads(_ allowed: Bool) {
        cellularAllowed.withLock { $0 = allowed }
    }

    #if DEBUG
    /// Test hook: drives the reachability transitions a cache built with
    /// `monitorsNetwork: false` never receives — including the reconnect
    /// notification renderers listen for to retry failed tiles.
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

    /// Registers a reconnect listener; held weakly, so no explicit removal is
    /// required (though ``removeObserver(_:)`` is available).
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

    func notifyReconnect() {
        // MKOverlayRenderer.setNeedsDisplay must run on the main thread; the path
        // handler fires on a background queue, so hop first, then read observers
        // there (keeps the non-Sendable listeners off the queue boundary).
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let live = observers.withLock { boxes -> [TileCacheObserver] in
                boxes.removeAll { $0.value == nil }
                return boxes.compactMap(\.value)
            }
            live.forEach { $0.tileCacheDidReconnect() }
        }
    }
}
