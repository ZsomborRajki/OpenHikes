//
//  WeatherRequestState.swift
//  OpenHikes
//
//  When the app may spend a WeatherKit request, and on what.
//
//  This replaced `WeatherPollState`, which keyed everything on a ~1.1 km
//  lat/lon grid derived from the hiker's position. The grid was only ever a
//  proxy for "has the subject changed", and a bad one: its keys flipped back
//  and forth underneath a hiker standing on a boundary, which needed an
//  eight-bucket LRU to absorb, and it could not express the three things the
//  badge is now about — a recording, a selected trail, a searched city — at
//  all. Keying on ``WeatherSubject/key`` says the same thing directly, and the
//  boundary case stops existing rather than being worked around.
//
//  The other change is that *why* a request is being considered now matters.
//  A hiker who has just searched for a city is owed an answer immediately; a
//  significant-change event is worth a request but not an unlimited number of
//  them; a hiker who asks where they are is looking at the badge for the
//  answer, and is owed a newer one than a reading that is merely not old
//  yet; a reading that has simply expired can wait for its deadline. One
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
    /// The floor under requests the hiker's movement asks for, and under
    /// the ones they ask for themselves at the map's location button.
    ///
    /// Significant-change delivery is already coarse — hundreds of metres at
    /// best, and cell-handoff driven rather than distance driven — so this is
    /// not there to thin out a stream that arrives too fast. It is there so a
    /// burst of events during a drive, or a receiver flapping between two
    /// cells, cannot turn into a burst of metered requests. A button pressed
    /// over and over is the same burst by hand.
    ///
    /// A movement it refuses is not forgotten: the subject comes due when
    /// the floor runs out — see
    /// ``WeatherRequestState/shouldRequest(key:reason:at:policy:isAsking:)``.
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
    /// The hiker asked where they are, at the map's location button — see
    /// ``WeatherFocus/focusOnHiker(at:)``. They are looking at the badge for
    /// the answer, so a reading a focus would still call fresh is asked for
    /// again once it is older than the movement floor.
    case asked
    /// The reading for the current subject reached its freshness deadline
    /// with nothing else having happened.
    case expiry
    /// The subject itself changed — a search resolved, a hike was selected, a
    /// recording started. The user asked, so the bar is the freshness of what
    /// is already held for *that* subject and nothing else.
    case focus
    /// Significant-change delivery moved the hiker, and the subject follows
    /// them.
    case movement
}

/// Decides when the weather poll may spend a WeatherKit request for a subject.
///
/// State is kept per ``WeatherSubject/key``, so a trail re-selected after a
/// detour finds its reading still fresh, and a subject never asked about
/// before is requested immediately.
nonisolated struct WeatherRequestState: Sendable {
    /// How many subjects to remember. A hiker can only have looked at so many
    /// places recently, and this is a freshness memory rather than a cache of
    /// the world — ``WeatherManager`` keeps the readings themselves under the
    /// same limit so the two cannot disagree about what is remembered.
    static let trackedSubjectLimit = 8

    private struct Entry: Sendable {
        var lastSuccess: Date?
        var failureCount = 0
        var nextAttempt: Date?
        /// Whether the subject has moved since the last request about it
        /// was sent: a movement its floor refused, or one that found that
        /// request still out. The reading held, or on its way, is for where
        /// the subject was — see ``shouldRequest(key:reason:at:policy:isAsking:)``.
        var owesMovement = false
    }

    /// Ordered least- to most-recently used, which is the whole eviction
    /// policy: touching a subject moves it to the end, so the one to drop
    /// is always the first.
    private var entries: OrderedDictionary<String, Entry> = [:]

    /// Whether to ask about `key` now. `isAsking` is whether a request about
    /// it is already out, which is never repeated.
    ///
    /// **A movement that has to wait is owed.** Its floor refuses it, or it
    /// finds a request about where the subject was still out, and either way
    /// the reading the badge ends up with is for the old position. Left at
    /// that, it stood until the reading expired: a launch whose first fix
    /// arrived a moment after significant-change delivery's cached one drew
    /// the cached position's forecast for a quarter of an hour. So the
    /// subject comes due at the movement floor instead — see
    /// ``nextEligibleDate(key:policy:)`` — and is held to that floor whatever
    /// wakes the poll, until a request about where it is now goes out.
    mutating func shouldRequest(
        key: String,
        reason: WeatherRequestReason,
        at now: Date,
        policy: WeatherPollingPolicy = .standard,
        isAsking: Bool = false
    ) -> Bool {
        let willRequest = Self.isDue(entries[key], for: reason, at: now, policy: policy) && !isAsking
        update(key) { entry in
            if willRequest {
                entry.owesMovement = false
            } else if reason == .movement {
                entry.owesMovement = true
            }
        }
        return willRequest
    }

    private static func isDue(
        _ entry: Entry?,
        for reason: WeatherRequestReason,
        at now: Date,
        policy: WeatherPollingPolicy
    ) -> Bool {
        // Never asked about this subject: genuinely new ground, so ask.
        guard let entry else { return true }

        // A failure's backoff is honoured whatever the reason, including a
        // fresh search. When WeatherKit is refusing — a bad entitlement, a
        // rate limit, no signal — a user retrying by hand is exactly the case
        // the ladder exists for, and letting `.focus` or `.asked` past it
        // would turn the search field, or the location button, into a way to
        // hammer a service that has already said no four times.
        if let nextAttempt = entry.nextAttempt { return now >= nextAttempt }

        guard let lastSuccess = entry.lastSuccess else { return true }
        return now.timeIntervalSince(lastSuccess) >= Self.minimumInterval(for: reason, of: entry, policy: policy)
    }

    private static func minimumInterval(
        for reason: WeatherRequestReason,
        of entry: Entry,
        policy: WeatherPollingPolicy
    ) -> TimeInterval {
        if entry.owesMovement { return policy.minimumRequestInterval }
        return switch reason {
        case .focus, .expiry: policy.freshnessInterval
        case .movement, .asked: policy.minimumRequestInterval
        }
    }

    /// Counts a reading for `key`.
    ///
    /// `inFront` is the subject the hiker is looking at, when the answer is
    /// another's: a request that was still out when they moved on. It stays
    /// the most recently used, because a run of those answers would
    /// otherwise push it out of the memory, and with it the freshness or
    /// backoff that its next request is timed by.
    mutating func recordSuccess(key: String, at now: Date, keeping inFront: String? = nil) {
        update(key, keeping: inFront) { entry in
            entry.lastSuccess = now
            entry.failureCount = 0
            entry.nextAttempt = nil
        }
    }

    /// Counts a failure for `key`, keeping `inFront` as
    /// ``recordSuccess(key:at:keeping:)`` does.
    mutating func recordFailure(
        key: String,
        at now: Date,
        policy: WeatherPollingPolicy = .standard,
        keeping inFront: String? = nil
    ) {
        update(key, keeping: inFront) { entry in
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
    /// expires — or a failure whose backoff runs out — while the hiker stands
    /// still is still refreshed on time.
    ///
    /// Deliberately non-mutating: asking when a subject comes due is not the
    /// same as asking about it, and must not reorder the recency list that
    /// decides which subject is forgotten first.
    ///
    /// A subject owed a movement comes due at the movement floor rather than
    /// when its reading expires: that reading is for where it was.
    func nextEligibleDate(
        key: String,
        policy: WeatherPollingPolicy = .standard
    ) -> Date? {
        guard let entry = entries[key] else { return nil }
        if let nextAttempt = entry.nextAttempt { return nextAttempt }
        guard let lastSuccess = entry.lastSuccess else { return nil }
        return lastSuccess.addingTimeInterval(
            entry.owesMovement ? policy.minimumRequestInterval : policy.freshnessInterval
        )
    }

    /// Applies `change` to `key`'s entry and marks it the most recently used,
    /// or the one just behind `inFront` when that is another remembered key,
    /// evicting the least recent one if that puts the memory over its limit.
    private mutating func update(
        _ key: String,
        keeping inFront: String? = nil,
        _ change: (inout Entry) -> Void
    ) {
        // Two separate things, said separately: the entry is changed where it
        // sits, and *then* moved to the end of the recency order. A key not
        // seen before is appended by `updateValue`, so the move that follows
        // finds it already last and does nothing.
        entries.updateValue(forKey: key, default: Entry(), with: change)
        entries.move(keys: CollectionOfOne(key), to: entries.count)
        if let inFront, inFront != key, entries[inFront] != nil {
            entries.move(keys: CollectionOfOne(inFront), to: entries.count)
        }
        if entries.count > Self.trackedSubjectLimit {
            entries.removeFirst()
        }
    }
}
