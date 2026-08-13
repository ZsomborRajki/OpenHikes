//
//  WeatherManager.swift
//  OpenTrails
//
//  Fetches current conditions for a coordinate via WeatherKit.
//

import Foundation
import CoreLocation
import OrderedCollections
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

    private mutating func touch(_ key: String) {
        update(key) { _ in }
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
