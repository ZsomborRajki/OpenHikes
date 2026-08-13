//
//  TileRetryTests.swift
//  OpenTrailsTests
//
//  A tile that fails to load is skipped on later draw passes, or the renderer
//  would re-request it on every frame. The question this suite exists for is
//  when the skip ends.
//
//  It used to end only when `NWPathMonitor` reported an offline→online
//  transition. That is the right answer for a tile that failed *because* the
//  app was offline, and the wrong one for every other reason a tile load
//  returns nil — a 500 from a busy tile server, a timeout, a rate limit, a
//  truncated response that won't decode. None of those move the network's
//  reachability, so nothing cleared them, and the tile stayed a hole in the
//  map for the whole life of the renderer no matter how much the user panned
//  back to it. On OpenStreetMap's shared, community-funded tile servers,
//  transient errors are not the unusual case.
//
//  `TileFailureLog` is deliberately a plain value type so all of that is
//  testable without a network, a map view, or a draw pass.
//

import Foundation
@testable import OpenTrails
import Testing

@Suite("Tile retry")
struct TileRetryTests {
    private let key = "osm/14/2638/6357@2.0"
    private let other = "osm/14/2638/6358@2.0"
    private let start = ContinuousClock.now

    private func log(
        delays: [Duration] = [.seconds(5), .seconds(15), .seconds(45)],
        maximumTrackedFailures: Int = 1024
    ) -> TileFailureLog {
        TileFailureLog(
            policy: TileRetryPolicy(delays: delays, maximumTrackedFailures: maximumTrackedFailures)
        )
    }

    // MARK: The defect this replaces

    /// The headline. A tile that failed once, while the network was up the
    /// whole time, is asked for again — without a reconnect, without the user
    /// doing anything.
    @Test("a tile that failed while online is tried again")
    func failedTileIsRetriedWhileOnline() {
        var log = log()
        log.recordFailure(key, at: start)

        #expect(!log.mayAttempt(key, at: start, isOnline: true), "not immediately — that was the request loop")
        #expect(!log.mayAttempt(key, at: start.advanced(by: .seconds(4)), isOnline: true))
        #expect(log.mayAttempt(key, at: start.advanced(by: .seconds(5)), isOnline: true))
    }

    /// A tile nothing has said anything about is always fair game.
    @Test("a tile that has never failed is never skipped")
    func unknownTileIsAlwaysAttempted() {
        let log = log()
        #expect(log.mayAttempt(key, at: start, isOnline: true))
        #expect(log.mayAttempt(key, at: start, isOnline: false))
    }

    // MARK: Backoff

    /// Consecutive failures back off, so a tile that is genuinely a 404 is not
    /// re-requested every five seconds for as long as the app is open —
    /// OpenStreetMap's usage policy cares about exactly that.
    @Test("repeated failures back off, up to the ceiling")
    func repeatedFailuresBackOff() {
        var log = log()

        log.recordFailure(key, at: start)
        #expect(log.mayAttempt(key, at: start.advanced(by: .seconds(5)), isOnline: true))

        log.recordFailure(key, at: start)
        #expect(!log.mayAttempt(key, at: start.advanced(by: .seconds(14)), isOnline: true))
        #expect(log.mayAttempt(key, at: start.advanced(by: .seconds(15)), isOnline: true))

        log.recordFailure(key, at: start)
        #expect(!log.mayAttempt(key, at: start.advanced(by: .seconds(44)), isOnline: true))
        #expect(log.mayAttempt(key, at: start.advanced(by: .seconds(45)), isOnline: true))

        // Past the end of the table, the last delay is the ceiling rather than
        // a crash or an ever-growing wait.
        log.recordFailure(key, at: start)
        log.recordFailure(key, at: start)
        #expect(log.mayAttempt(key, at: start.advanced(by: .seconds(45)), isOnline: true))
    }

    /// The ceiling holds however many times a tile fails — this is the one
    /// that would overflow or run away if the index arithmetic were wrong.
    @Test("the backoff ceiling holds after many failures")
    func ceilingHoldsUnderRepetition() {
        var log = log()
        for _ in 0..<500 { log.recordFailure(key, at: start) }
        #expect(log.mayAttempt(key, at: start.advanced(by: .seconds(45)), isOnline: true))
    }

    /// A tile that loads forgets its history, so an unrelated failure an hour
    /// later starts at five seconds rather than at the ceiling.
    @Test("a tile that loads starts its next backoff from scratch")
    func successResetsTheBackoff() {
        var log = log()
        log.recordFailure(key, at: start)
        log.recordFailure(key, at: start)
        log.recordSuccess(key)

        #expect(log.mayAttempt(key, at: start, isOnline: true), "nothing is held against it any more")
        log.recordFailure(key, at: start)
        #expect(log.mayAttempt(key, at: start.advanced(by: .seconds(5)), isOnline: true), "back to the first delay")
    }

    /// Backoff is per tile: one bad tile must not delay its neighbours.
    @Test("one tile's backoff doesn't hold up another")
    func backoffIsPerTile() {
        var log = log()
        log.recordFailure(key, at: start)
        log.recordFailure(key, at: start)

        #expect(log.mayAttempt(other, at: start, isOnline: true))
        log.recordFailure(other, at: start)
        #expect(log.mayAttempt(other, at: start.advanced(by: .seconds(5)), isOnline: true))
        #expect(!log.mayAttempt(key, at: start.advanced(by: .seconds(5)), isOnline: true))
    }

    // MARK: Offline

    /// While offline, `TileCache` short-circuits the request anyway, so a
    /// timer that made tiles eligible one backoff at a time would only spend
    /// work to be told no. Failures are held indefinitely and released all at
    /// once by the reconnect — which is both cheaper and faster to recover.
    @Test("backoff doesn't release tiles while the app is offline")
    func offlineHoldsFailuresIndefinitely() {
        var log = log()
        log.recordFailure(key, at: start)

        #expect(!log.mayAttempt(key, at: start.advanced(by: .seconds(5)), isOnline: false))
        #expect(!log.mayAttempt(key, at: start.advanced(by: .seconds(6 * 60 * 60)), isOnline: false))
        #expect(
            log.mayAttempt(key, at: start.advanced(by: .seconds(5)), isOnline: true),
            "and are released the moment it's back"
        )
    }

    /// Reconnecting invalidates every past failure at once, whatever each
    /// one's backoff had left to run — they were all recorded against a
    /// network that no longer applies.
    @Test("reconnecting clears every failure regardless of backoff")
    func reconnectClearsEverything() {
        var log = log()
        log.recordFailure(key, at: start)
        for _ in 0..<5 { log.recordFailure(other, at: start) }
        #expect(log.count == 2)

        let cleared = log.removeAll()
        #expect(cleared == 2)
        #expect(log.count == 0)
        #expect(log.mayAttempt(key, at: start, isOnline: true))
        #expect(log.mayAttempt(other, at: start, isOnline: true))
    }

    // MARK: Bounds

    /// The set used to grow with every tile the user panned across while a
    /// provider misbehaved, and never shrink.
    @Test("the log never grows past its cap")
    func logIsBounded() {
        var log = log(maximumTrackedFailures: 10)
        for index in 0..<200 {
            log.recordFailure("osm/14/\(index)/0@2.0", at: start)
        }
        #expect(log.count == 10)
    }

    /// What eviction gives up matters: dropping a tile deep in its backoff
    /// would restart it at five seconds and undo the point of backing off, so
    /// the ones nearest to being retried go first — forgetting those costs at
    /// most the early retry they were about to get anyway.
    @Test("eviction keeps the tiles still serving a long backoff")
    func evictionKeepsTheLongestBackoffs() {
        var log = log(maximumTrackedFailures: 2)

        // `patient` has failed three times, so it's furthest from eligible.
        let patient = "osm/14/1/1@2.0"
        for _ in 0..<3 { log.recordFailure(patient, at: start) }
        // Two fresh single failures, both due much sooner.
        log.recordFailure("osm/14/2/2@2.0", at: start)
        log.recordFailure("osm/14/3/3@2.0", at: start)

        #expect(log.count == 2)
        #expect(log.retryTime(for: patient) != nil, "the tile with the most invested backoff is kept")
    }

    // MARK: Waking up to retry

    /// The renderer only retries during a draw pass, and nothing forces one
    /// while the map sits still — so the log reports when the soonest tile
    /// comes due and the renderer schedules a redraw for then. Without it a
    /// user who stops panning keeps staring at the hole.
    @Test("the soonest retry is the one the renderer waits for")
    func earliestRetryIsTheSoonestDeadline() {
        var log = log()
        #expect(log.earliestRetry() == nil, "nothing has failed, so there's nothing to wake up for")

        // `other` has failed twice (15 s) and `key` once (5 s).
        log.recordFailure(other, at: start)
        log.recordFailure(other, at: start)
        log.recordFailure(key, at: start)

        #expect(log.earliestRetry() == start.advanced(by: .seconds(5)))

        log.recordSuccess(key)
        #expect(log.earliestRetry() == start.advanced(by: .seconds(15)), "with it gone, the next one is due")

        log.recordSuccess(other)
        #expect(log.earliestRetry() == nil)
    }

    // MARK: The shipped policy

    /// The defaults the app actually runs with, pinned separately from the
    /// mechanism so a change to either is a deliberate one.
    @Test("the standard policy escalates from seconds to minutes")
    func standardPolicyShape() {
        let policy = TileRetryPolicy.standard
        #expect(policy.delay(afterFailures: 1) == .seconds(5), "a transient error heals almost invisibly")
        #expect(policy.delay(afterFailures: 2) == .seconds(15))
        #expect(policy.delay(afterFailures: 3) == .seconds(45))
        #expect(policy.delay(afterFailures: 4) == .seconds(120))
        #expect(policy.delay(afterFailures: 5) == .seconds(300))
        #expect(
            policy.delay(afterFailures: 50) == .seconds(300),
            "a real 404 settles at one request every five minutes"
        )

        // Every delay is longer than the last, or the backoff isn't one.
        for (previous, next) in zip(policy.delays, policy.delays.dropFirst()) {
            #expect(next > previous)
        }
        #expect(policy.maximumTrackedFailures > 0)
    }
}
