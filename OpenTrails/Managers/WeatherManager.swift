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

nonisolated struct WeatherPollState: Sendable {
    private(set) var key: String?
    private(set) var lastSuccess: Date?
    private(set) var failureCount = 0
    private(set) var nextAttempt: Date?

    mutating func shouldRequest(
        key newKey: String,
        at now: Date,
        policy: WeatherPollingPolicy = .standard
    ) -> Bool {
        if key != newKey {
            key = newKey
            lastSuccess = nil
            failureCount = 0
            nextAttempt = nil
            return true
        }
        if let nextAttempt {
            return now >= nextAttempt
        }
        guard let lastSuccess else { return true }
        return now.timeIntervalSince(lastSuccess) >= policy.freshnessInterval
    }

    mutating func recordSuccess(key: String, at now: Date) {
        self.key = key
        lastSuccess = now
        failureCount = 0
        nextAttempt = nil
    }

    mutating func recordFailure(
        key: String,
        at now: Date,
        policy: WeatherPollingPolicy = .standard
    ) {
        self.key = key
        lastSuccess = nil
        failureCount += 1
        nextAttempt = now.addingTimeInterval(policy.retryDelay(after: failureCount))
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
