//
//  WeatherOwedMovementTests.swift
//  OpenHikesTests
//
//  What ``WeatherRequestState`` owes a movement it could not ask about.
//
//  A movement is refused by its floor, or finds a request about where the
//  subject was still out. Either way the reading the badge ends up with is
//  for the old position, and it used to stand until it expired: a launch
//  whose first fix landed a moment after significant-change delivery's
//  cached one drew the cached position's forecast for a quarter of an hour.
//  So the subject comes due at the movement floor, and stays held to that
//  floor, whatever wakes the poll, until a request about where it is goes
//  out.
//
//  Its own suite beside ``WeatherRequestStateTests``, which is about which
//  floor a reason gets and has no room for a second question.
//

import Foundation
@testable import OpenHikes
import Testing

@Suite("Weather owed movement")
struct WeatherOwedMovementTests {
    private let policy = WeatherPollingPolicy(
        freshnessInterval: 900,
        minimumRequestInterval: 60,
        retryDelays: [5, 30, 120]
    )
    private let start = Date(timeIntervalSinceReferenceDate: 1_000_000)

    private func after(_ seconds: TimeInterval) -> Date {
        start.addingTimeInterval(seconds)
    }

    @Test("a movement its floor refused comes due when the floor runs out, not when the reading expires")
    func aRefusedMovementComesDueAtItsFloor() {
        var state = WeatherRequestState()
        state.recordSuccess(key: "me", at: start)

        let tooSoon = state.shouldRequest(key: "me", reason: .movement, at: after(10), policy: policy)
        #expect(!tooSoon)

        #expect(state.nextEligibleDate(key: "me", policy: policy) == after(60))
    }

    /// The deadline wakes the poll as an expiry, and so might a focus. The
    /// subject is held to the movement floor for either.
    @Test("a movement owed is asked about at its floor, whatever wakes the poll")
    func anOwedMovementIsHeldToItsFloor() {
        var state = WeatherRequestState()
        state.recordSuccess(key: "me", at: start)
        _ = state.shouldRequest(key: "me", reason: .movement, at: after(10), policy: policy)

        let early = state.shouldRequest(key: "me", reason: .expiry, at: after(59), policy: policy)
        #expect(!early)
        let due = state.shouldRequest(key: "me", reason: .expiry, at: after(60), policy: policy)
        #expect(due, "the reading is a minute old, and for where the hiker was")
    }

    @Test("a request sent pays the movement, and the next reading has its whole freshness")
    func aRequestPaysTheMovement() {
        var state = WeatherRequestState()
        state.recordSuccess(key: "me", at: start)
        _ = state.shouldRequest(key: "me", reason: .movement, at: after(10), policy: policy)
        _ = state.shouldRequest(key: "me", reason: .expiry, at: after(60), policy: policy)

        state.recordSuccess(key: "me", at: after(61))

        #expect(state.nextEligibleDate(key: "me", policy: policy) == after(61 + 900))
        let again = state.shouldRequest(key: "me", reason: .expiry, at: after(61 + 60), policy: policy)
        #expect(!again)
    }

    /// The launch this is for: the cached location's request is still out
    /// when the first fix lands, and its answer is about the cached place.
    @Test("a movement that finds the request still out is owed one when the answer lands")
    func aMovementWhileAskingIsOwed() {
        var state = WeatherRequestState()
        let first = state.shouldRequest(key: "me", reason: .movement, at: start, policy: policy)
        #expect(first, "new ground")

        let whileOut = state.shouldRequest(
            key: "me", reason: .movement, at: after(1), policy: policy, isAsking: true
        )
        #expect(!whileOut, "one request about a subject at a time")
        state.recordSuccess(key: "me", at: after(2))

        #expect(state.nextEligibleDate(key: "me", policy: policy) == after(2 + 60))
    }

    /// The control: the same request, found out by something that is not a
    /// movement, owes nothing.
    @Test("a focus that finds the request still out owes nothing")
    func aFocusWhileAskingOwesNothing() {
        var state = WeatherRequestState()
        _ = state.shouldRequest(key: "me", reason: .focus, at: start, policy: policy)

        let whileOut = state.shouldRequest(
            key: "me", reason: .focus, at: after(1), policy: policy, isAsking: true
        )
        #expect(!whileOut)
        state.recordSuccess(key: "me", at: after(2))

        #expect(state.nextEligibleDate(key: "me", policy: policy) == after(2 + 900))
    }

    /// The subject moves, and a focus wake follows the movement's: the same
    /// change, heard twice. It must not take back what the movement is owed.
    @Test("a focus that finds the request still out leaves a movement owed")
    func aFocusWhileAskingKeepsTheMovementOwed() {
        var state = WeatherRequestState()
        _ = state.shouldRequest(key: "me", reason: .movement, at: start, policy: policy)
        _ = state.shouldRequest(key: "me", reason: .movement, at: after(1), policy: policy, isAsking: true)

        _ = state.shouldRequest(key: "me", reason: .focus, at: after(1), policy: policy, isAsking: true)
        state.recordSuccess(key: "me", at: after(2))

        #expect(state.nextEligibleDate(key: "me", policy: policy) == after(2 + 60))
    }

    @Test("a movement owed does not bypass a failure's backoff")
    func anOwedMovementHonorsBackoff() {
        var state = WeatherRequestState()
        state.recordFailure(key: "me", at: start, policy: policy)

        let duringBackoff = state.shouldRequest(key: "me", reason: .movement, at: after(1), policy: policy)
        #expect(!duringBackoff)
        #expect(state.nextEligibleDate(key: "me", policy: policy) == after(5), "the retry, which asks about here")
        let afterBackoff = state.shouldRequest(key: "me", reason: .expiry, at: after(5), policy: policy)
        #expect(afterBackoff)
    }
}
