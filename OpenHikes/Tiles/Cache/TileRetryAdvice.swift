//
//  TileRetryAdvice.swift
//  OpenHikes
//
//  When a tile server has told us, in so many words, how long to stay away.
//
//  A 429 or a 503 with `Retry-After` is the one failure where the server
//  names its own deadline, and treating it as a generic miss meant the client
//  came back on ``TileRetryPolicy``'s five seconds — the shortest delay it
//  has — for a server that had just said it was overloaded. On OSM's
//  community-funded tiles that is the request pattern their usage policy
//  exists to discourage.
//
//  This deliberately does *not* add a second backoff. ``TileFailureLog``
//  already decides when a failed tile may be asked for again, and what a
//  server asks for is fed into that decision as a floor: the tile waits for
//  whichever is longer, the policy's own escalating delay or the server's
//  deadline. A `Retry-After: 1` therefore cannot shorten a backoff that has
//  already escalated to five minutes, and nothing here can make the client
//  more eager than it was.
//
//  A deadline is kept for the URL that was refused, not for the tile key:
//  it is that server's answer about that request. Two styles can ask one
//  URL — OpenStreetMap's raster template is both the comparison style and
//  the fallback of the style drawn from vector tiles — and the OpenHikes tile
//  server asked ahead of that fallback is not the server that refused.
//

import Algorithms
import Foundation
import OpenHikesVectorTiles
import Synchronization

/// The deadlines servers have asked for, by the URL they refused.
///
/// Bounded for the same reason ``TileFailureLog`` is: a provider having a bad
/// afternoon can refuse every tile a user pans across, and a table that only
/// ever grows would hold them all. Entries are dropped as they come due, so
/// in practice this holds only the tiles refused inside the current window.
nonisolated struct TileRetryAdvice: Sendable {
    /// Ceiling on how many deadlines are remembered at once.
    static let maximumTrackedKeys = 512

    private var deadlines: [String: ContinuousClock.Instant] = [:]

    var count: Int { deadlines.count }

    /// Records that `key` may not be asked for before `notBefore`, keeping the
    /// later of that and anything already recorded — a second refusal from a
    /// server that is still overloaded must not shorten the first one.
    mutating func record(
        _ key: String,
        notBefore: ContinuousClock.Instant,
        at now: ContinuousClock.Instant
    ) {
        prune(at: now)
        if let existing = deadlines[key], existing >= notBefore { return }
        deadlines[key] = notBefore
        evictIfNeeded()
    }

    /// The deadline still standing for `key`, if a server named one.
    func deadline(for key: String, at now: ContinuousClock.Instant) -> ContinuousClock.Instant? {
        guard let deadline = deadlines[key], deadline > now else { return nil }
        return deadline
    }

    private mutating func prune(at now: ContinuousClock.Instant) {
        deadlines = deadlines.filter { $0.value > now }
    }

    /// Drops the entries closest to coming due, exactly as ``TileFailureLog``
    /// does: forgetting one costs at most an early retry it was about to be
    /// allowed anyway, while forgetting the tile a server most recently asked
    /// us to leave alone is the one that matters.
    private mutating func evictIfNeeded() {
        let excess = deadlines.count - Self.maximumTrackedKeys
        guard excess > 0 else { return }
        // Sorted on the key as well as the instant, since entries recorded in
        // the same instant would otherwise be offered up in a hash-seeded
        // order.
        let doomed = deadlines.min(count: excess) { lhs, rhs in
            lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value < rhs.value
        }
        for entry in doomed { deadlines.removeValue(forKey: entry.key) }
    }
}

nonisolated extension TileCache {

    /// Files whatever `response` to a request for `url` asked for, so the
    /// request is not made again before then and the renderer's backoff can
    /// honour it when the load it belongs to comes back a failure.
    ///
    /// Recorded against the cache rather than returned up the call chain
    /// because a fetch is shared: the map and a bulk download can be waiting
    /// on one request, and both should hear what the server said.
    func recordRetryAdvice(from response: HTTPURLResponse, for url: URL) {
        guard let delay = RetryAfterHeader.delay(from: response) else { return }
        let now = ContinuousClock.now
        retryAdvice.withLock { $0.record(url.absoluteString, notBefore: now.advanced(by: delay), at: now) }
    }

    /// When a server last said `url` may be asked for again, if that moment
    /// has not passed.
    ///
    /// Left in place rather than consumed by the read: two renderers can be
    /// drawing the same provider, and a deadline that the first one to fail
    /// took away from the second would be honoured by neither. It expires on
    /// its own.
    func retryDeadline(for url: URL) -> ContinuousClock.Instant? {
        retryAdvice.withLock { $0.deadline(for: url.absoluteString, at: .now) }
    }

    /// The deadline a renderer's backoff for `key` takes as its floor: the
    /// one standing for `url`, the request a load of `key` makes, unless the
    /// provider is drawn from vector tiles. A load of one of those asks the
    /// OpenHikes tile server first, which keeps its own pause, and waits out
    /// a deadline of its raster template only on the way to it, so the
    /// renderer backs off on its own delays and the tile is drawn again as
    /// soon as the tile server can draw it.
    func retryDeadline(forKey key: String, url: URL) -> ContinuousClock.Instant? {
        isDrawnFromVectorTiles(key) ? nil : retryDeadline(for: url)
    }
}
