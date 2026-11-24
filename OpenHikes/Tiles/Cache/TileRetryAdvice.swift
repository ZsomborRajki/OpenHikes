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

import Foundation
import HeapModule
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
    static let honoredStatusCodes: Set<Int> = [tooManyRequests, serviceUnavailable]

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
        guard honoredStatusCodes.contains(response.statusCode),
              let value = response.value(forHTTPHeaderField: name)
        else { return nil }
        return delay(from: value, now: now)
    }

    private static func clamped(_ delay: Duration) -> Duration? {
        guard delay > .zero else { return nil }
        return min(delay, maximumDelay)
    }

    /// The IMF-fixdate reader, configured once.
    ///
    /// This used to build a `DateFormatter` per call, on the stated grounds
    /// that `DateFormatter` is not `Sendable` and so could not be held in a
    /// `static let`. That was never true of this SDK — `NSDateFormatter.h`
    /// declares `NS_SWIFT_SENDABLE`, "all mutable state protected by locks" —
    /// and a `Date.ParseStrategy` is a value type, so the question does not
    /// arise at all.
    ///
    /// Field for field the same grammar `"EEE, dd MMM yyyy HH:mm:ss zzz"`
    /// expressed, with `.specificName(.short)` standing in for `zzz`: `GMT`
    /// and `UTC` are read, a named zone that is not one of them is refused,
    /// and `zzz`'s tolerance of `+0000` is kept. Not a `Date.FormatStyle`,
    /// which is a localized rendering of a date for a person to read, where
    /// this is a wire format that is the same in every locale.
    private static let imfFixdate = Date.ParseStrategy(
        format: """
        \(weekday: .abbreviated), \(day: .twoDigits) \(month: .abbreviated) \
        \(year: .padded(4)) \
        \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\
        \(minute: .twoDigits):\(second: .twoDigits) \
        \(timeZone: .specificName(.short))
        """,
        locale: Locale(identifier: "en_US_POSIX"),
        timeZone: .gmt,
        isLenient: false
    )

    /// Matched whole rather than parsed from the front: `parse(_:)` stops as
    /// soon as it has a date and would read `…07:28:00 GMT and change` as a
    /// deadline, where the formatter this replaced refused it. The header's
    /// value is the date or it is not advice.
    private static func httpDate(_ value: String) -> Date? {
        value.wholeMatch(of: imfFixdate)?.output
    }
}

/// The deadlines servers have asked for, by the URL they refused.
///
/// Bounded for the same reason ``TileFailureLog`` is: a provider having a bad
/// afternoon can refuse every tile a user pans across, and a table that only
/// ever grows would hold them all. Entries are dropped as they come due, so
/// in practice this holds only the tiles refused inside the current window.
///
/// Two stores, because this is written under the cache's lock on every
/// refusal and read under it by every renderer. The dictionary answers a
/// key's deadline at once. The heap orders them by when they come due, so
/// pruning what is due and evicting what is closest to due take only those
/// entries, where both used to walk the whole table: at the cap, a burst of
/// refusals scanned it twice for each one.
nonisolated struct TileRetryAdvice: Sendable {
    /// Ceiling on how many deadlines are remembered at once.
    static let maximumTrackedKeys = 512

    /// One deadline as the heap holds it: ordered by when it comes due, and
    /// on its key within one instant, so ties go the same way every time
    /// rather than in a hash-seeded order.
    private struct Expiry: Comparable, Sendable {
        let deadline: ContinuousClock.Instant
        let key: String

        static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.deadline == rhs.deadline ? lhs.key < rhs.key : lhs.deadline < rhs.deadline
        }
    }

    private var deadlines: [String: ContinuousClock.Instant] = [:]
    /// Every deadline recorded, soonest first. A deadline pushed out leaves
    /// its earlier entry here, stale once ``deadlines`` holds the later one;
    /// a stale entry is skipped as it surfaces, and the heap is rebuilt from
    /// ``deadlines`` once it holds twice the keys the table may keep, so
    /// repeated extensions cannot grow it.
    private var expiries = Heap<Expiry>()

    var count: Int { deadlines.count }

    /// How many entries the heap holds, stale ones included — for a suite to
    /// hold it to its bound.
    var indexedCount: Int { expiries.count }

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
        expiries.insert(Expiry(deadline: notBefore, key: key))
        evictIfNeeded()
        compactIfNeeded()
    }

    /// The deadline still standing for `key`, if a server named one.
    func deadline(for key: String, at now: ContinuousClock.Instant) -> ContinuousClock.Instant? {
        guard let deadline = deadlines[key], deadline > now else { return nil }
        return deadline
    }

    private mutating func prune(at now: ContinuousClock.Instant) {
        while let soonest = expiries.min, soonest.deadline <= now {
            forget(expiries.removeMin())
        }
    }

    /// Drops the entries closest to coming due, exactly as ``TileFailureLog``
    /// does: forgetting one costs at most an early retry it was about to be
    /// allowed anyway, while forgetting the tile a server most recently asked
    /// us to leave alone is the one that matters.
    private mutating func evictIfNeeded() {
        while deadlines.count > Self.maximumTrackedKeys, let soonest = expiries.popMin() {
            forget(soonest)
        }
    }

    /// Drops `entry`'s key, unless a later deadline has replaced the one it
    /// carries — then it was stale, and the key's own entry is still to come.
    private mutating func forget(_ entry: Expiry) {
        if deadlines[entry.key] == entry.deadline { deadlines.removeValue(forKey: entry.key) }
    }

    private mutating func compactIfNeeded() {
        guard expiries.count > 2 * Self.maximumTrackedKeys else { return }
        expiries = Heap(deadlines.map { Expiry(deadline: $0.value, key: $0.key) })
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
