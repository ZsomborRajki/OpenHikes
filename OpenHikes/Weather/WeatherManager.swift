//
//  WeatherManager.swift
//  OpenHikes
//
//  Fetches current conditions for a coordinate via WeatherKit.
//

import CoreLocation
import Foundation
import Observation
import OrderedCollections
import os
import WeatherKit

nonisolated struct WeatherPollingPolicy: Sendable {
    static let standard = Self(
        freshnessInterval: 15 * 60,
        retryDelays: [5, 30, 2 * 60, 15 * 60]
    )

    let freshnessInterval: TimeInterval
    let retryDelays: [TimeInterval]

    func retryDelay(after failureCount: Int) -> TimeInterval {
        guard !retryDelays.isEmpty else { return freshnessInterval }
        return retryDelays[min(max(failureCount - 1, 0), retryDelays.count - 1)]
    }
}

/// Decides when the weather poll may spend a WeatherKit request.
///
/// State is kept **per location bucket**, and that's the whole design. It used
/// to be a single bucket's worth, reset wholesale whenever the key changed —
/// which is right for someone who has moved, and wrong for someone standing on
/// a bucket boundary, where consecutive fixes land on either side of it.
/// Neither the freshness interval nor the failure backoff applied there,
/// because both were keyed to the bucket that had just changed, so an
/// oscillation spent a metered request on every one-second poll, indefinitely.
/// Bucket edges are a fixed ~1.1 km grid over the world; a trail crosses one
/// every kilometre or so.
///
/// Remembering each bucket separately removes the special case rather than
/// putting a floor under it: coming back to a bucket polled moments ago finds
/// its reading still fresh, and a bucket never polled before is still
/// requested immediately.
nonisolated struct WeatherPollState: Sendable {
    /// How many buckets to remember. Enough to cover the handful a walker can
    /// oscillate between — four meet at a grid corner — with room to spare,
    /// and small enough that this stays a boundary guard rather than a cache
    /// of the world.
    static let trackedBucketLimit = 8

    private struct BucketState: Sendable {
        var lastSuccess: Date?
        var failureCount = 0
        var nextAttempt: Date?
    }

    /// Ordered least- to most-recently polled, which is the whole eviction
    /// policy: touching a bucket re-inserts it at the end, so the one to drop
    /// is always the first. An unordered `Dictionary` needed a `touchedAt` on
    /// every entry and a sort of all of them to find the same bucket.
    private var buckets: OrderedDictionary<String, BucketState> = [:]

    mutating func shouldRequest(
        key: String,
        at now: Date,
        policy: WeatherPollingPolicy = .standard
    ) -> Bool {
        let existing = buckets[key]
        touch(key)

        // Never polled here: genuinely new ground, so ask.
        guard let existing else { return true }
        if let nextAttempt = existing.nextAttempt { return now >= nextAttempt }
        guard let lastSuccess = existing.lastSuccess else { return true }
        return now.timeIntervalSince(lastSuccess) >= policy.freshnessInterval
    }

    mutating func recordSuccess(key: String, at now: Date) {
        update(key) { state in
            state.lastSuccess = now
            state.failureCount = 0
            state.nextAttempt = nil
        }
    }

    mutating func recordFailure(
        key: String,
        at now: Date,
        policy: WeatherPollingPolicy = .standard
    ) {
        update(key) { state in
            state.lastSuccess = nil
            state.failureCount += 1
            state.nextAttempt = now.addingTimeInterval(policy.retryDelay(after: state.failureCount))
        }
    }

    /// When ``shouldRequest(key:at:policy:)`` will next say yes for `key`, or
    /// `nil` if it already does.
    ///
    /// The poll wakes on a new position; this is what tells it when to wake
    /// *without* one, so a reading that expires — or a failure whose backoff
    /// runs out — while the walker stands still is still refreshed on time.
    /// Deliberately non-mutating: asking when a bucket comes due is not the
    /// same as polling it, and must not reorder the recency list that decides
    /// which bucket is forgotten first.
    func nextEligibleDate(
        key: String,
        policy: WeatherPollingPolicy = .standard
    ) -> Date? {
        guard let state = buckets[key] else { return nil }
        if let nextAttempt = state.nextAttempt { return nextAttempt }
        guard let lastSuccess = state.lastSuccess else { return nil }
        return lastSuccess.addingTimeInterval(policy.freshnessInterval)
    }

    private mutating func touch(_ key: String) {
        update(key) { _ in /* no-op: just moves key to most-recently-used position */ }
    }

    /// Applies `change` to `key`'s state and marks it the most recently
    /// polled bucket, evicting the least recent one if that puts the memory
    /// over its limit.
    private mutating func update(_ key: String, _ change: (inout BucketState) -> Void) {
        // Removed and re-inserted rather than mutated in place, so the key
        // moves to the end of the recency order instead of staying where it
        // first appeared.
        var state = buckets.removeValue(forKey: key) ?? BucketState()
        change(&state)
        buckets[key] = state
        if buckets.count > Self.trackedBucketLimit {
            buckets.removeFirst()
        }
    }
}

/// What the badge over the map actually draws: a symbol, a temperature and a
/// sentence.
///
/// A value type rather than WeatherKit's `CurrentWeather` for two reasons.
/// `CurrentWeather` has no public initializer, so nothing — a preview, a test,
/// a UI automation launch — could ever stand one up, which left the badge the
/// only piece of the interface reachable solely by a live network call against
/// an entitlement. And the badge reads three fields out of a type with
/// dozens, so the narrower value says what it depends on.
nonisolated struct WeatherSnapshot: Equatable, Sendable {
    let symbolName: String
    let temperature: Measurement<UnitTemperature>
    let conditionDescription: String

    init(
        symbolName: String,
        temperature: Measurement<UnitTemperature>,
        conditionDescription: String
    ) {
        self.symbolName = symbolName
        self.temperature = temperature
        self.conditionDescription = conditionDescription
    }

    init(_ weather: CurrentWeather) {
        self.init(
            symbolName: weather.symbolName,
            temperature: weather.temperature,
            conditionDescription: weather.condition.description
        )
    }
}

@Observable
final class WeatherManager {
    @ObservationIgnored private static let logger = Logger(
        subsystem: "OpenHikes",
        category: "Weather"
    )

    /// The reading the badge draws, or `nil` while there has never been one.
    private(set) var current: WeatherSnapshot?

    private let service = WeatherService.shared

    /// Publishes a fixed reading instead of asking WeatherKit.
    ///
    /// Only reachable from a `--ui-test-weather` launch: the badge is the one
    /// control on the first screen whose presence depends on an entitlement, a
    /// token and a network round trip, so without this it was either absent
    /// from every automated run or a source of flakes in all of them.
    #if DEBUG
    func applyUITestSnapshot(_ snapshot: WeatherSnapshot = .uiTestFixture) {
        current = snapshot
    }
    #endif

    /// Fetches current weather for the given coordinate, preserving the last
    /// successful reading when WeatherKit is temporarily unavailable.
    func update(for coordinate: CLLocationCoordinate2D) async -> Bool {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        // Instrumented because WeatherKit is a network call this app makes on
        // a walker's behalf without being asked, and the 15-minute freshness
        // window that keeps it rare is a constant nobody would notice
        // regressing. The count per hike is the check.
        let interval = RenderSignpost.beginInterval("WeatherFetch")
        defer { RenderSignpost.endInterval("WeatherFetch", interval) }
        do {
            current = WeatherSnapshot(
                try await service.weather(for: location, including: .current)
            )
            return true
        } catch {
            // The caller only learns "no". WeatherKit's failure modes are the
            // opaque ones — a missing entitlement, a token fetch that failed, a
            // rate limit, an unsupported region — and they are indistinguishable
            // from a walker simply being out of signal, which is the one the
            // backoff is designed for. Without this there is no signal anywhere
            // that tells the two apart.
            Self.logger.error(
                "Weather update failed: \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }
}

#if DEBUG
extension WeatherSnapshot {
    /// The reading `--ui-test-weather` publishes.
    ///
    /// Deliberately unmistakable: a temperature no simulator's real location
    /// is likely to report, so a test that finds this value knows the badge is
    /// drawing the fixture rather than something that arrived by accident.
    static let uiTestFixture = Self(
        symbolName: "cloud.sun.fill",
        temperature: Measurement(value: 12, unit: UnitTemperature.celsius),
        conditionDescription: "Partly Cloudy"
    )
}
#endif
