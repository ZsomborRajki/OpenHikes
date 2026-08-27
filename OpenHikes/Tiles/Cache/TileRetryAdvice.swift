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

import Algorithms
import Foundation
import Synchronization

/// Reads `Retry-After` off a response.
nonisolated enum RetryAfterHeader {
    static let name = "Retry-After"

    static let tooManyRequests = 429
    static let serviceUnavailable = 503

    /// The statuses whose `Retry-After` is worth honouring.
    ///
    /// 429 is the rate limit itself; 503 is what a tile server returns when
    /// it is shedding load, and OSM's infrastructure uses both. A 404 or a
    /// 500 may carry the header too, but neither says anything about *this*
    /// client's request rate, so neither should be allowed to park a tile.
    static let honouredStatusCodes: Set<Int> = [tooManyRequests, serviceUnavailable]

    /// Longest delay honoured. A header asking for a day — or a misparsed
    /// date that looks like one — must not take a tile off the map until the
    /// app is relaunched. Fifteen minutes is already three times
    /// ``TileRetryPolicy``'s own ceiling, so anything past it is answering a
    /// question about server capacity that a reconnect or a relaunch will
    /// re-ask anyway.
    static let maximumDelay: Duration = .seconds(15 * 60)

    /// How long `value` asks the client to wait, or `nil` when it asks for
    /// nothing usable.
    ///
    /// RFC 9110 allows two spellings: delta-seconds, and an HTTP-date. Only
    /// the IMF-fixdate form of the latter is parsed — the RFC 850 and asctime
    /// forms are obsolete and no tile server sends them — and a value in
    /// neither form is treated as no advice at all rather than as a reason to
    /// guess.
    ///
    /// A deadline already in the past, or a delay of zero, is `nil` rather
    /// than `.zero`: it would lower the floor to nothing, and the caller's own
    /// backoff is what should decide then.
    static func delay(from value: String, now: Date = Date()) -> Duration? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        if let seconds = Int(trimmed) {
            return clamped(.seconds(seconds))
        }
        guard let date = httpDate(trimmed) else { return nil }
        let interval = date.timeIntervalSince(now)
        guard interval.isFinite else { return nil }
        return clamped(.seconds(interval))
    }

    /// The advice in `response`, if it is a status that carries any.
    static func delay(from response: HTTPURLResponse, now: Date = Date()) -> Duration? {
        guard honouredStatusCodes.contains(response.statusCode),
              let value = response.value(forHTTPHeaderField: name)
        else { return nil }
        return delay(from: value, now: now)
    }

    private static func clamped(_ delay: Duration) -> Duration? {
        guard delay > .zero else { return nil }
        return min(delay, maximumDelay)
    }

    /// Built per call rather than held in a static: `DateFormatter` is not
    /// `Sendable`, this runs only when a server has already refused a request,
    /// and a shared one would need a lock to buy back microseconds nobody is
    /// waiting on.
    private static func httpDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value)
    }
}

/// The deadlines servers have asked for, by tile key.
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

    /// Files whatever `response` asked for, so the renderer's backoff can
    /// honour it when the load it belongs to comes back a failure.
    ///
    /// Recorded against the cache rather than returned up the call chain
    /// because a fetch is shared: the map and a bulk download can be waiting
    /// on one request, and both should hear what the server said.
    func recordRetryAdvice(from response: HTTPURLResponse, forKey key: String) {
        guard let delay = RetryAfterHeader.delay(from: response) else { return }
        let now = ContinuousClock.now
        retryAdvice.withLock { $0.record(key, notBefore: now.advanced(by: delay), at: now) }
        RenderSignpost.mark(
            "TileRetryAfterHonoured",
            "key=\(key) status=\(response.statusCode) seconds=\(delay.components.seconds)"
        )
    }

    /// When a server last said `key` may be asked for again, if that moment
    /// has not passed.
    ///
    /// Left in place rather than consumed by the read: two renderers can be
    /// drawing the same provider, and a deadline that the first one to fail
    /// took away from the second would be honoured by neither. It expires on
    /// its own.
    func retryDeadline(forKey key: String) -> ContinuousClock.Instant? {
        retryAdvice.withLock { $0.deadline(for: key, at: .now) }
    }
}
