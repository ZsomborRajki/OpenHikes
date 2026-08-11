//
//  WeatherManager.swift
//  OpenTrails
//
//  Fetches current conditions for a coordinate via WeatherKit.
//

import Foundation
import CoreLocation
import WeatherKit
import Observation

nonisolated struct WeatherPollingPolicy: Sendable {
    static let standard = WeatherPollingPolicy(
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
        /// Last time this bucket was polled, for eviction only.
        var touchedAt: Date
    }

    private var buckets: [String: BucketState] = [:]

    mutating func shouldRequest(
        key: String,
        at now: Date,
        policy: WeatherPollingPolicy = .standard
    ) -> Bool {
        let existing = buckets[key]
        touch(key, at: now)

        // Never polled here: genuinely new ground, so ask.
        guard let existing else { return true }
        if let nextAttempt = existing.nextAttempt { return now >= nextAttempt }
        guard let lastSuccess = existing.lastSuccess else { return true }
        return now.timeIntervalSince(lastSuccess) >= policy.freshnessInterval
    }

    mutating func recordSuccess(key: String, at now: Date) {
        update(key, at: now) { state in
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
        update(key, at: now) { state in
            state.lastSuccess = nil
            state.failureCount += 1
            state.nextAttempt = now.addingTimeInterval(policy.retryDelay(after: state.failureCount))
        }
    }

    private mutating func touch(_ key: String, at now: Date) {
        update(key, at: now) { _ in }
    }

    private mutating func update(_ key: String, at now: Date, _ change: (inout BucketState) -> Void) {
        var state = buckets[key] ?? BucketState(touchedAt: now)
        state.touchedAt = now
        change(&state)
        buckets[key] = state
        evictOldestIfNeeded()
    }

    /// Keeps the most recently polled buckets. A walk in a straight line visits
    /// a new bucket every kilometre or so, and nothing about a bucket left
    /// behind is worth carrying for the rest of the hike.
    private mutating func evictOldestIfNeeded() {
        guard buckets.count > Self.trackedBucketLimit else { return }
        let survivors = buckets
            .sorted { $0.value.touchedAt > $1.value.touchedAt }
            .prefix(Self.trackedBucketLimit)
        buckets = Dictionary(uniqueKeysWithValues: survivors.map { ($0.key, $0.value) })
    }
}

@MainActor
@Observable
final class WeatherManager {
    private(set) var current: CurrentWeather?

    private let service = WeatherService.shared

    /// Fetches current weather for the given coordinate, preserving the last
    /// successful reading when WeatherKit is temporarily unavailable.
    func update(for coordinate: CLLocationCoordinate2D) async -> Bool {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        do {
            current = try await service.weather(for: location, including: .current)
            return true
        } catch {
            return false
        }
    }
}
