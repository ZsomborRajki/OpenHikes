//
//  WeatherRequestState.swift
//  OpenHikes
//
//  When the app may spend a WeatherKit request, and on what.
//
//  This replaced ``WeatherPollState``, which keyed everything on a ~1.1 km
//  lat/lon grid derived from the walker's position. The grid was only ever a
//  proxy for "has the subject changed", and a bad one: its keys flipped back
//  and forth underneath a walker standing on a boundary, which needed an
//  eight-bucket LRU to absorb, and it could not express the three things the
//  badge is now about — a recording, a selected trail, a searched city — at
//  all. Keying on ``WeatherSubject/key`` says the same thing directly, and the
//  boundary case stops existing rather than being worked around.
//
//  The other change is that *why* a request is being considered now matters.
//  A walker who has just searched for a city is owed an answer immediately; a
//  significant-change event is worth a request but not an unlimited number of
//  them; a reading that has simply expired can wait for its deadline. One
//  floor per reason, in ``minimumInterval(for:policy:)``, is the whole of it.
//

import Foundation
import OrderedCollections

nonisolated struct WeatherPollingPolicy: Sendable {
    static let standard = Self(
        freshnessInterval: 15 * 60,
        minimumRequestInterval: 60,
        retryDelays: [5, 30, 2 * 60, 15 * 60]
    )

    /// How long a successful reading counts as current. Also the floor under
    /// requests driven by focus and by expiry.
    let freshnessInterval: TimeInterval
    /// The floor under movement-driven requests.
    ///
    /// Significant-change delivery is already coarse — hundreds of metres at
    /// best, and cell-handoff driven rather than distance driven — so this is
    /// not there to thin out a stream that arrives too fast. It is there so a
    /// burst of events during a drive, or a receiver flapping between two
    /// cells, cannot turn into a burst of metered requests.
    let minimumRequestInterval: TimeInterval
    let retryDelays: [TimeInterval]

    func retryDelay(after failureCount: Int) -> TimeInterval {
        guard !retryDelays.isEmpty else { return freshnessInterval }
        return retryDelays[min(max(failureCount - 1, 0), retryDelays.count - 1)]
    }
}

/// Why a request is being considered. Decides how long since the last one is
/// long enough; see ``WeatherRequestState/shouldRequest(key:reason:at:policy:)``.
nonisolated enum WeatherRequestReason: Sendable {
    /// The reading for the current subject reached its freshness deadline
    /// with nothing else having happened.
    case expiry
    /// The subject itself changed — a search resolved, a hike was selected, a
    /// recording started. The user asked, so the bar is the freshness of what
    /// is already held for *that* subject and nothing else.
    case focus
    /// Significant-change delivery moved the walker, and the subject follows
    /// them.
    case movement
}

/// Decides when the weather poll may spend a WeatherKit request for a subject.
///
/// State is kept per ``WeatherSubject/key``, so a trail re-selected after a
/// detour finds its reading still fresh, and a subject never asked about
/// before is requested immediately.
nonisolated struct WeatherRequestState: Sendable {
    /// How many subjects to remember. A walker can only have looked at so many
    /// places recently, and this is a freshness memory rather than a cache of
    /// the world — ``WeatherManager`` keeps the readings themselves under the
    /// same limit so the two cannot disagree about what is remembered.
    static let trackedSubjectLimit = 8

    private struct Entry: Sendable {
        var lastSuccess: Date?
        var failureCount = 0
        var nextAttempt: Date?
    }

    /// Ordered least- to most-recently used, which is the whole eviction
    /// policy: touching a subject re-inserts it at the end, so the one to drop
    /// is always the first.
    private var entries: OrderedDictionary<String, Entry> = [:]

    mutating func shouldRequest(
        key: String,
        reason: WeatherRequestReason,
        at now: Date,
        policy: WeatherPollingPolicy = .standard
    ) -> Bool {
        let existing = entries[key]
        touch(key)

        // Never asked about this subject: genuinely new ground, so ask.
        guard let existing else { return true }

        // A failure's backoff is honoured whatever the reason, including a
        // fresh search. When WeatherKit is refusing — a bad entitlement, a
        // rate limit, no signal — a user retrying by hand is exactly the case
        // the ladder exists for, and letting `.focus` past it would turn the
        // search field into a way to hammer a service that has already said no
        // four times.
        if let nextAttempt = existing.nextAttempt { return now >= nextAttempt }

        guard let lastSuccess = existing.lastSuccess else { return true }
        return now.timeIntervalSince(lastSuccess) >= Self.minimumInterval(for: reason, policy: policy)
    }

    private static func minimumInterval(
        for reason: WeatherRequestReason,
        policy: WeatherPollingPolicy
    ) -> TimeInterval {
        switch reason {
        case .focus, .expiry: policy.freshnessInterval
        case .movement: policy.minimumRequestInterval
        }
    }

    mutating func recordSuccess(key: String, at now: Date) {
        update(key) { entry in
            entry.lastSuccess = now
            entry.failureCount = 0
            entry.nextAttempt = nil
        }
    }

    mutating func recordFailure(
        key: String,
        at now: Date,
        policy: WeatherPollingPolicy = .standard
    ) {
        update(key) { entry in
            entry.lastSuccess = nil
            entry.failureCount += 1
            entry.nextAttempt = now.addingTimeInterval(policy.retryDelay(after: entry.failureCount))
        }
    }

    /// When this subject next comes due without anything else happening, or
    /// `nil` if it is not waiting on a clock at all.
    ///
    /// The poll wakes on a new subject and on significant-change delivery;
    /// this is what tells it when to wake *without* either, so a reading that
    /// expires — or a failure whose backoff runs out — while the walker stands
    /// still is still refreshed on time.
    ///
    /// Deliberately non-mutating: asking when a subject comes due is not the
    /// same as asking about it, and must not reorder the recency list that
    /// decides which subject is forgotten first.
    func nextEligibleDate(
        key: String,
        policy: WeatherPollingPolicy = .standard
    ) -> Date? {
        guard let entry = entries[key] else { return nil }
        if let nextAttempt = entry.nextAttempt { return nextAttempt }
        guard let lastSuccess = entry.lastSuccess else { return nil }
        return lastSuccess.addingTimeInterval(policy.freshnessInterval)
    }

    private mutating func touch(_ key: String) {
        update(key) { _ in /* no-op: just moves key to most-recently-used position */ }
    }

    /// Applies `change` to `key`'s entry and marks it the most recently used,
    /// evicting the least recent one if that puts the memory over its limit.
    private mutating func update(_ key: String, _ change: (inout Entry) -> Void) {
        // Removed and re-inserted rather than mutated in place, so the key
        // moves to the end of the recency order instead of staying where it
        // first appeared.
        var entry = entries.removeValue(forKey: key) ?? Entry()
        change(&entry)
        entries[key] = entry
        if entries.count > Self.trackedSubjectLimit {
            entries.removeFirst()
        }
    }
}
