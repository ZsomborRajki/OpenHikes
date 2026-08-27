//
//  TileFailureLog.swift
//  OpenHikes
//
//  Which tiles have failed to load, and when each may be asked for again.
//
//  This used to be a bare `Set<String>` inside `CachingTileOverlayRenderer`,
//  cleared only when `NWPathMonitor` reported an offline→online transition.
//  That is the right response to *being offline*, and the wrong one to every
//  other way a tile load fails: a 500 from a busy tile server, a timeout, a
//  rate limit, a truncated response that won't decode. None of those change
//  the network's reachability, so nothing ever cleared them — and the tile
//  rendered as a hole (or as a stretched crop of its parent) for the whole
//  life of the renderer, however much the user panned back to it.
//
//  So failures now expire. A tile that failed once is worth another try in a
//  few seconds; a tile that has failed five times is probably a real 404 and
//  is worth one every few minutes. Reconnecting still clears the lot at once,
//  because that is the one event that invalidates every past failure.
//
//  Split out of the renderer so the policy can be tested without a network,
//  a map, or a draw pass — the renderer keeps only the MapKit glue.
//

import Algorithms
import Foundation

/// How long to wait before re-requesting a tile that failed, by how many
/// times in a row it has now failed.
nonisolated struct TileRetryPolicy: Sendable {
    static let standard = Self()

    private static let maximumRetryDelaySecs: Int = 300

    /// In consecutive-failure order, so the first failure waits `delays[0]`;
    /// the last entry is the ceiling.
    ///
    /// The first retry is deliberately quick — a single transient error on a
    /// shared tile server is the common case, and five seconds is short
    /// enough that a user panning around won't notice the gap heal. The
    /// ceiling is deliberately long: by the fifth failure the tile is
    /// probably genuinely absent, and the cost of asking is a request the
    /// provider's usage policy would rather we didn't make.
    var delays: [Duration] = [
        .seconds(5), .seconds(15), .seconds(45), .seconds(120), .seconds(Self.maximumRetryDelaySecs)
    ]

    /// Ceiling on how many failed tiles are remembered at once. Without one
    /// this grows with every tile the user ever pans across while a provider
    /// is misbehaving, and never shrinks.
    var maximumTrackedFailures: Int = 1024

    func delay(afterFailures failures: Int) -> Duration {
        guard let last = delays.last else { return .seconds(Self.maximumRetryDelaySecs) }
        guard failures > 0 else { return delays[0] }
        return failures <= delays.count ? delays[failures - 1] : last
    }
}

/// A bounded, self-expiring record of failed tile loads.
nonisolated struct TileFailureLog: Sendable {
    private struct Entry: Sendable {
        var failures: Int
        var retryAt: ContinuousClock.Instant
    }

    let policy: TileRetryPolicy
    private var entries: [String: Entry] = [:]

    init(policy: TileRetryPolicy = .standard) {
        self.policy = policy
    }

    var count: Int { entries.count }

    /// Whether this tile may be requested right now.
    ///
    /// A tile with no failure behind it always may. One that has failed waits
    /// out its backoff — and, while the app is offline, waits indefinitely:
    /// `TileCache` would short-circuit the request anyway, and
    /// ``removeAll()`` on reconnect is what heals every tile at once rather
    /// than one backoff at a time.
    func mayAttempt(_ key: String, at now: ContinuousClock.Instant, isOnline: Bool) -> Bool {
        guard let entry = entries[key] else { return true }
        guard isOnline else { return false }
        return now >= entry.retryAt
    }

    /// Records a failure and returns when the tile may next be tried.
    ///
    /// `notBefore` is a floor a server named for itself — a `Retry-After` on a
    /// 429 or a 503, see ``RetryAfterHeader``. It can only ever push the
    /// deadline out: a server asking for one second must not undo a backoff
    /// that has already escalated to five minutes, and the escalation itself
    /// carries on regardless, so a tile that keeps failing keeps backing off
    /// whether or not anyone is advising it.
    @discardableResult mutating func recordFailure(
        _ key: String,
        at now: ContinuousClock.Instant,
        notBefore serverDeadline: ContinuousClock.Instant? = nil
    ) -> ContinuousClock.Instant {
        let failures = (entries[key]?.failures ?? 0) + 1
        var retryAt = now.advanced(by: policy.delay(afterFailures: failures))
        if let serverDeadline, serverDeadline > retryAt { retryAt = serverDeadline }
        entries[key] = Entry(failures: failures, retryAt: retryAt)
        evictIfNeeded()
        return retryAt
    }

    /// Forgets a tile that has since loaded, so a later failure starts its
    /// backoff from the beginning rather than from where the last run of bad
    /// luck left off.
    mutating func recordSuccess(_ key: String) {
        entries.removeValue(forKey: key)
    }

    /// Forgets everything, and reports how much — the reconnect path, where
    /// every past failure is equally out of date.
    @discardableResult mutating func removeAll() -> Int {
        let cleared = entries.count
        entries.removeAll()
        return cleared
    }

    /// When the soonest tile still waiting on its backoff becomes eligible, so
    /// the renderer can arrange to redraw then instead of waiting for the user
    /// to pan.
    ///
    /// Deadlines at or before `now` are excluded, and that exclusion is what
    /// makes the wake-up safe to arm from a draw pass. A tile past its deadline
    /// is already being attempted — it is in flight, or the pass that is asking
    /// just started it — so a timer for it would fire immediately, redraw, find
    /// the same past deadline and arm again: the redraw-per-draw loop the
    /// backoff exists to prevent.
    func earliestRetry(after now: ContinuousClock.Instant) -> ContinuousClock.Instant? {
        entries.values.lazy.map(\.retryAt).filter { $0 > now }.min()
    }

    /// Test seam: when `key` may next be attempted, if it has failed at all.
    func retryTime(for key: String) -> ContinuousClock.Instant? {
        entries[key]?.retryAt
    }

    /// Drops the entries closest to being retried. Forgetting one costs at
    /// most an early retry — which is what it was about to get anyway — while
    /// forgetting a tile still deep in its backoff would restart it at five
    /// seconds and undo the whole point of backing off.
    ///
    /// Only the handful over the cap need finding, so this is a partial
    /// selection rather than an ordering of all thousand-odd entries — this
    /// runs on every recorded failure once the cap is reached, which is
    /// exactly when a provider is misbehaving and failures arrive fastest.
    private mutating func evictIfNeeded() {
        let excess = entries.count - policy.maximumTrackedFailures
        guard excess > 0 else { return }
        // Sorted on the key as well as the instant: entries recorded in the
        // same instant share a retry time, and `Dictionary` would otherwise
        // offer them up in a hash-seeded order.
        let doomed = entries.min(count: excess) { lhs, rhs in
            lhs.value.retryAt == rhs.value.retryAt
                ? lhs.key < rhs.key
                : lhs.value.retryAt < rhs.value.retryAt
        }
        for entry in doomed { entries.removeValue(forKey: entry.key) }
    }
}
