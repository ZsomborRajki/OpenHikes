//
//  WeatherPollingTests.swift
//  OpenTrailsTests
//

import Foundation
import Testing
@testable import OpenTrails

@Suite("Weather polling")
struct WeatherPollingTests {
    private let policy = WeatherPollingPolicy(
        freshnessInterval: 900,
        retryDelays: [5, 30, 120]
    )
    private let start = Date(timeIntervalSinceReferenceDate: 1_000_000)

    @Test("a failure retries with capped backoff")
    func failureBackoff() {
        var state = WeatherPollState()

        var shouldRequest = state.shouldRequest(key: "47,12", at: start, policy: policy)
        #expect(shouldRequest)
        state.recordFailure(key: "47,12", at: start, policy: policy)
        shouldRequest = state.shouldRequest(key: "47,12", at: start.addingTimeInterval(4), policy: policy)
        #expect(!shouldRequest)
        shouldRequest = state.shouldRequest(key: "47,12", at: start.addingTimeInterval(5), policy: policy)
        #expect(shouldRequest)

        state.recordFailure(key: "47,12", at: start.addingTimeInterval(5), policy: policy)
        shouldRequest = state.shouldRequest(key: "47,12", at: start.addingTimeInterval(34), policy: policy)
        #expect(!shouldRequest)
        shouldRequest = state.shouldRequest(key: "47,12", at: start.addingTimeInterval(35), policy: policy)
        #expect(shouldRequest)

        state.recordFailure(key: "47,12", at: start.addingTimeInterval(35), policy: policy)
        state.recordFailure(key: "47,12", at: start.addingTimeInterval(155), policy: policy)
        shouldRequest = state.shouldRequest(key: "47,12", at: start.addingTimeInterval(274), policy: policy)
        #expect(!shouldRequest)
        shouldRequest = state.shouldRequest(key: "47,12", at: start.addingTimeInterval(275), policy: policy)
        #expect(shouldRequest)
    }

    @Test("a successful reading refreshes after it expires")
    func successfulReadingFreshness() {
        var state = WeatherPollState()
        state.recordSuccess(key: "47,12", at: start)

        var shouldRequest = state.shouldRequest(key: "47,12", at: start.addingTimeInterval(899), policy: policy)
        #expect(!shouldRequest)
        shouldRequest = state.shouldRequest(key: "47,12", at: start.addingTimeInterval(900), policy: policy)
        #expect(shouldRequest)
    }

    @Test("moving to a new area requests immediately")
    func movementResetsBackoff() {
        var state = WeatherPollState()
        state.recordFailure(key: "47,12", at: start, policy: policy)

        let shouldRequest = state.shouldRequest(key: "48,13", at: start.addingTimeInterval(1), policy: policy)
        #expect(shouldRequest)
    }
}
