//
//  WeatherPollingTests.swift
//  OpenHikesTests
//

import Foundation
@testable import OpenHikes
import Testing

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

    /// `OpenHikesModel` buckets the user's position to two decimal places —
    /// about 1.1 km — and GPS noise on a boundary lands consecutive fixes on
    /// either side of it. A state that remembered only the current bucket
    /// would read every crossing as new ground and request again, because both
    /// the freshness interval and the failure backoff are keyed to the bucket
    /// that just changed.
    ///
    /// A boundary is not a corner case here: bucket edges are a fixed 1.1 km
    /// grid laid over the world, and a trail crosses one every kilometre or so.
    @Test("hovering on a bucket boundary doesn't request every second")
    func boundaryOscillationIsThrottled() {
        var state = WeatherPollState()
        var requests = 0

        // Twenty seconds of polling while GPS noise flips the bucket.
        for second in 0..<20 {
            let key = second.isMultiple(of: 2) ? "4763,1286" : "4763,1287"
            let now = start.addingTimeInterval(Double(second))
            if state.shouldRequest(key: key, at: now, policy: policy) {
                requests += 1
                state.recordSuccess(key: key, at: now)
            }
        }

        #expect(requests <= 2, "two adjacent buckets, one reading each")
    }

    /// The backoff has to survive the boundary too. A bucket that failed and a
    /// bucket that hasn't been tried are different situations, and hopping
    /// between them mustn't launder the first into the second — that was the
    /// same escape hatch, reached through `nextAttempt` instead of freshness.
    @Test("a failing bucket keeps its backoff across a boundary hop")
    func backoffSurvivesBoundaryOscillation() {
        var state = WeatherPollState()
        var requests = 0

        for second in 0..<20 {
            let key = second.isMultiple(of: 2) ? "4763,1286" : "4763,1287"
            let now = start.addingTimeInterval(Double(second))
            if state.shouldRequest(key: key, at: now, policy: policy) {
                requests += 1
                state.recordFailure(key: key, at: now, policy: policy)
            }
        }

        // Each bucket: one attempt, then a 5 s delay, then a second attempt and
        // a 30 s delay that outlasts the window. Four requests, not twenty.
        #expect(requests <= 4, "each bucket backs off on its own schedule")
    }

    /// The memory is bounded, and bounded by *recency* — a walker crossing
    /// buckets in a line must not accumulate one entry per kilometre, and the
    /// bucket they're standing in must not be the one evicted.
    @Test("only the most recent buckets are remembered")
    func bucketMemoryIsBounded() {
        var state = WeatherPollState()
        let limit = WeatherPollState.trackedBucketLimit

        // Walk far enough to overflow the memory several times over.
        for step in 0..<(limit * 3) {
            let now = start.addingTimeInterval(Double(step))
            let key = "4763,\(1286 + step)"
            let isNewGround = state.shouldRequest(key: key, at: now, policy: policy)
            #expect(isNewGround, "each is new ground")
            state.recordSuccess(key: key, at: now)
        }

        let afterTheWalk = start.addingTimeInterval(Double(limit * 3))

        // The bucket just left is still remembered…
        let last = "4763,\(1286 + limit * 3 - 1)"
        let revisitsLast = state.shouldRequest(key: last, at: afterTheWalk, policy: policy)
        #expect(!revisitsLast, "stepping back over the last boundary finds a fresh reading")

        // …and one from the start of the walk has been forgotten, which is
        // correct: it's kilometres behind, and its reading would be stale.
        let revisitsFirst = state.shouldRequest(key: "4763,1286", at: afterTheWalk, policy: policy)
        #expect(revisitsFirst)
    }

    /// The behaviour any fix has to keep: someone who really has moved — far
    /// enough to land in a different bucket — gets fresh weather without
    /// waiting out the freshness interval for the place they left.
    @Test("a genuine move still refreshes before the interval is up")
    func realMovementStillRefreshes() {
        var state = WeatherPollState()
        state.recordSuccess(key: "4763,1286", at: start)

        let sameBucket = state.shouldRequest(key: "4763,1286", at: start.addingTimeInterval(60), policy: policy)
        #expect(!sameBucket, "still fresh where it was measured")
        let kilometreAway = state.shouldRequest(key: "4800,1300", at: start.addingTimeInterval(60), policy: policy)
        #expect(kilometreAway)
    }

    /// The poll no longer ticks once a second, so it has to be told when to
    /// come back: it wakes on a published fix, and otherwise on this deadline.
    /// A walker standing still with an expiring reading depends entirely on
    /// it — without it, "refresh every fifteen minutes" quietly becomes
    /// "refresh whenever they next move".
    @Test("a fresh reading comes due when its freshness runs out")
    func nextEligibleFollowsFreshness() {
        var state = WeatherPollState()
        state.recordSuccess(key: "4763,1286", at: start)

        #expect(
            state.nextEligibleDate(key: "4763,1286", policy: policy)
                == start.addingTimeInterval(900)
        )
    }

    /// And a failed bucket comes due on its backoff, not on its freshness —
    /// the same order `shouldRequest` checks them in, so the poll can't sleep
    /// past a retry it was about to allow.
    @Test("a failed reading comes due on its backoff")
    func nextEligibleFollowsBackoff() {
        var state = WeatherPollState()
        state.recordFailure(key: "4763,1286", at: start, policy: policy)

        #expect(
            state.nextEligibleDate(key: "4763,1286", policy: policy)
                == start.addingTimeInterval(5),
            "the first retry delay"
        )

        state.recordFailure(key: "4763,1286", at: start.addingTimeInterval(5), policy: policy)
        #expect(
            state.nextEligibleDate(key: "4763,1286", policy: policy)
                == start.addingTimeInterval(35),
            "then the second"
        )
    }

    /// Ground never polled has no deadline to wait for, which is what tells
    /// the loop to request as soon as a fix puts the walker there.
    @Test("an unpolled bucket has no deadline")
    func nextEligibleIsNilForNewGround() {
        let state = WeatherPollState()
        #expect(state.nextEligibleDate(key: "4763,1286", policy: policy) == nil)
    }

    /// Asking when a bucket comes due must not count as polling it. The
    /// memory evicts by recency, so a mutating peek would let the loop's own
    /// bookkeeping decide which bucket is forgotten — and forget the one the
    /// walker is standing in.
    @Test("checking a deadline doesn't disturb the recency order")
    func nextEligibleDoesNotTouchRecency() {
        var state = WeatherPollState()
        let limit = WeatherPollState.trackedBucketLimit

        state.recordSuccess(key: "oldest", at: start)
        for step in 1..<limit {
            state.recordSuccess(key: "filler\(step)", at: start.addingTimeInterval(Double(step)))
        }

        // A peek at the oldest bucket, repeated: were it a touch, this alone
        // would promote it to most-recent and evict a filler instead.
        for _ in 0..<3 {
            _ = state.nextEligibleDate(key: "oldest", policy: policy)
        }
        state.recordSuccess(key: "newcomer", at: start.addingTimeInterval(Double(limit)))

        let revisitsOldest = state.shouldRequest(
            key: "oldest",
            at: start.addingTimeInterval(Double(limit) + 1),
            policy: policy
        )
        #expect(revisitsOldest, "the oldest bucket was still the one evicted")
    }
}
