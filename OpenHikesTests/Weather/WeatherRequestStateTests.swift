//
//  WeatherRequestStateTests.swift
//  OpenHikesTests
//
//  What the weather poll is allowed to spend, and when.
//
//  These used to be about a lat/lon grid, because the poll used to be: the
//  hiker's position was rounded to ~1.1 km and that rounding decided whether
//  a request was new ground. Half the suite existed to pin down what happened
//  on a grid boundary, which is a problem the grid invented — see
//  ``WeatherRequestState``. Keying on ``WeatherSubject/key`` deletes the
//  boundary, so those tests are gone and what is left is about the three
//  things that actually gate a request: freshness, backoff, and which of them
//  applies to the reason the poll woke up.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import Testing

@Suite("Weather request state")
struct WeatherRequestStateTests {
    private let policy = WeatherPollingPolicy(
        freshnessInterval: 900,
        minimumRequestInterval: 60,
        retryDelays: [5, 30, 120]
    )
    private let start = Date(timeIntervalSinceReferenceDate: 1_000_000)

    @Test("a subject never asked about is requested immediately")
    func newSubjectRequestsAtOnce() {
        var state = WeatherRequestState()
        let isNewGround = state.shouldRequest(
            key: "place:Budapest", reason: .focus, at: start, policy: policy
        )
        #expect(isNewGround)
    }

    @Test("a failure retries with capped backoff")
    func failureBackoff() {
        var state = WeatherRequestState()

        var shouldRequest = state.shouldRequest(key: "me", reason: .focus, at: start, policy: policy)
        #expect(shouldRequest)
        state.recordFailure(key: "me", at: start, policy: policy)
        shouldRequest = state.shouldRequest(
            key: "me", reason: .expiry, at: start.addingTimeInterval(4), policy: policy
        )
        #expect(!shouldRequest)
        shouldRequest = state.shouldRequest(
            key: "me", reason: .expiry, at: start.addingTimeInterval(5), policy: policy
        )
        #expect(shouldRequest)

        state.recordFailure(key: "me", at: start.addingTimeInterval(5), policy: policy)
        shouldRequest = state.shouldRequest(
            key: "me", reason: .expiry, at: start.addingTimeInterval(34), policy: policy
        )
        #expect(!shouldRequest)
        shouldRequest = state.shouldRequest(
            key: "me", reason: .expiry, at: start.addingTimeInterval(35), policy: policy
        )
        #expect(shouldRequest)

        state.recordFailure(key: "me", at: start.addingTimeInterval(35), policy: policy)
        state.recordFailure(key: "me", at: start.addingTimeInterval(155), policy: policy)
        shouldRequest = state.shouldRequest(
            key: "me", reason: .expiry, at: start.addingTimeInterval(274), policy: policy
        )
        #expect(!shouldRequest)
        shouldRequest = state.shouldRequest(
            key: "me", reason: .expiry, at: start.addingTimeInterval(275), policy: policy
        )
        #expect(shouldRequest)
    }

    /// The one thing a backoff must not have: an escape hatch. A hiker who
    /// searches the same city four times while WeatherKit is refusing is
    /// exactly the case the ladder is for, and `.focus` bypassing it would
    /// turn the search field into a way to hammer a service that has already
    /// said no.
    @Test("an explicit focus does not bypass a failure's backoff")
    func focusHonoursBackoff() {
        var state = WeatherRequestState()
        state.recordFailure(key: "place:Budapest", at: start, policy: policy)

        let duringBackoff = state.shouldRequest(
            key: "place:Budapest", reason: .focus, at: start.addingTimeInterval(4), policy: policy
        )
        #expect(!duringBackoff)
        let afterBackoff = state.shouldRequest(
            key: "place:Budapest", reason: .focus, at: start.addingTimeInterval(5), policy: policy
        )
        #expect(afterBackoff)
    }

    @Test("a successful reading refreshes after it expires")
    func successfulReadingFreshness() {
        var state = WeatherRequestState()
        state.recordSuccess(key: "me", at: start)

        var shouldRequest = state.shouldRequest(
            key: "me", reason: .expiry, at: start.addingTimeInterval(899), policy: policy
        )
        #expect(!shouldRequest)
        shouldRequest = state.shouldRequest(
            key: "me", reason: .expiry, at: start.addingTimeInterval(900), policy: policy
        )
        #expect(shouldRequest)
    }

    /// Movement is the reason with the short floor, and that is the whole
    /// point of carrying a reason at all: a hiker who has crossed a cell
    /// boundary has plausibly walked into different weather, and making them
    /// wait out the full freshness interval for it is what the old
    /// position-driven poll effectively did.
    @Test("movement refreshes on the short floor, not the freshness one")
    func movementUsesItsOwnFloor() {
        var state = WeatherRequestState()
        state.recordSuccess(key: "me", at: start)

        let tooSoon = state.shouldRequest(
            key: "me", reason: .movement, at: start.addingTimeInterval(59), policy: policy
        )
        #expect(!tooSoon)
        let allowed = state.shouldRequest(
            key: "me", reason: .movement, at: start.addingTimeInterval(60), policy: policy
        )
        #expect(allowed, "a minute after the last reading, having moved, is worth a request")

        // …and the same moment is *not* enough for the other two reasons.
        let byExpiry = state.shouldRequest(
            key: "me", reason: .expiry, at: start.addingTimeInterval(60), policy: policy
        )
        #expect(!byExpiry)
        let byFocus = state.shouldRequest(
            key: "me", reason: .focus, at: start.addingTimeInterval(60), policy: policy
        )
        #expect(!byFocus, "re-focusing a subject whose reading is still fresh spends nothing")
    }

    /// Freshness is per subject, which is what lets the badge move between
    /// them without paying for each move. Selecting a trail, searching a city
    /// and going back to the trail is three focuses and two requests.
    @Test("each subject keeps its own freshness")
    func freshnessIsPerSubject() {
        var state = WeatherRequestState()

        let trailIsNew = state.shouldRequest(key: "trail:A", reason: .focus, at: start, policy: policy)
        #expect(trailIsNew)
        state.recordSuccess(key: "trail:A", at: start)

        let city = start.addingTimeInterval(10)
        let cityIsNew = state.shouldRequest(
            key: "place:Budapest", reason: .focus, at: city, policy: policy
        )
        #expect(cityIsNew)
        state.recordSuccess(key: "place:Budapest", at: city)

        let back = start.addingTimeInterval(20)
        let revisitsTrail = state.shouldRequest(key: "trail:A", reason: .focus, at: back, policy: policy)
        #expect(
            !revisitsTrail,
            "the trail's reading is seconds old — going back to it spends nothing"
        )
    }

    /// A hiker moving does not make them a new subject. `me` is one subject
    /// whose coordinate changes, and the state must not treat a step as new
    /// ground the way the old grid key did every kilometre.
    @Test("the hiker moving is not a new subject")
    func movementDoesNotResetTheSubject() {
        var state = WeatherRequestState()
        state.recordSuccess(key: WeatherSubject.me(.init(latitude: 47.5, longitude: 19.0)).key, at: start)

        let movedKey = WeatherSubject.me(.init(latitude: 47.9, longitude: 19.4)).key
        let shouldRequest = state.shouldRequest(
            key: movedKey, reason: .expiry, at: start.addingTimeInterval(60), policy: policy
        )
        #expect(!shouldRequest, "still the same subject, and its reading is still fresh")
    }

    /// The memory is bounded, and bounded by *recency* — a hiker who searches
    /// their way across a map must not accumulate an entry per query, and the
    /// subject they are looking at must not be the one evicted.
    @Test("only the most recent subjects are remembered")
    func subjectMemoryIsBounded() {
        var state = WeatherRequestState()
        let limit = WeatherRequestState.trackedSubjectLimit

        for step in 0..<(limit * 3) {
            let now = start.addingTimeInterval(Double(step))
            let key = "place:city\(step)"
            let isNewGround = state.shouldRequest(key: key, reason: .focus, at: now, policy: policy)
            #expect(isNewGround, "each is new ground")
            state.recordSuccess(key: key, at: now)
        }

        let afterwards = start.addingTimeInterval(Double(limit * 3))

        let last = "place:city\(limit * 3 - 1)"
        let revisitsLast = state.shouldRequest(key: last, reason: .focus, at: afterwards, policy: policy)
        #expect(!revisitsLast, "the subject just left is still remembered")
        let revisitsFirst = state.shouldRequest(
            key: "place:city0", reason: .focus, at: afterwards, policy: policy
        )
        #expect(
            revisitsFirst,
            "and the first has been forgotten, which is correct — its reading would be stale"
        )
    }

    /// The poll does not tick, so it has to be told when to come back: it
    /// wakes on a new subject and on significant-change delivery, and
    /// otherwise on this deadline. A hiker standing still with an expiring
    /// reading depends entirely on it — without it, "refresh every fifteen
    /// minutes" quietly becomes "refresh whenever they next move".
    @Test("a fresh reading comes due when its freshness runs out")
    func nextEligibleFollowsFreshness() {
        var state = WeatherRequestState()
        state.recordSuccess(key: "me", at: start)

        #expect(state.nextEligibleDate(key: "me", policy: policy) == start.addingTimeInterval(900))
    }

    /// And a failed subject comes due on its backoff, not on its freshness —
    /// the same order `shouldRequest` checks them in, so the poll can't sleep
    /// past a retry it was about to allow.
    @Test("a failed reading comes due on its backoff")
    func nextEligibleFollowsBackoff() {
        var state = WeatherRequestState()
        state.recordFailure(key: "me", at: start, policy: policy)

        #expect(
            state.nextEligibleDate(key: "me", policy: policy) == start.addingTimeInterval(5),
            "the first retry delay"
        )

        state.recordFailure(key: "me", at: start.addingTimeInterval(5), policy: policy)
        #expect(
            state.nextEligibleDate(key: "me", policy: policy) == start.addingTimeInterval(35),
            "then the second"
        )
    }

    /// A subject never asked about has no deadline to wait for, which is what
    /// tells the loop to request as soon as one is focused.
    @Test("an unrequested subject has no deadline")
    func nextEligibleIsNilForNewSubjects() {
        let state = WeatherRequestState()
        #expect(state.nextEligibleDate(key: "me", policy: policy) == nil)
    }

    /// Asking when a subject comes due must not count as asking about it. The
    /// memory evicts by recency, so a mutating peek would let the loop's own
    /// bookkeeping decide which subject is forgotten — and forget the one on
    /// screen.
    @Test("checking a deadline doesn't disturb the recency order")
    func nextEligibleDoesNotTouchRecency() {
        var state = WeatherRequestState()
        let limit = WeatherRequestState.trackedSubjectLimit

        state.recordSuccess(key: "oldest", at: start)
        for step in 1..<limit {
            state.recordSuccess(key: "filler\(step)", at: start.addingTimeInterval(Double(step)))
        }

        // A peek at the oldest subject, repeated: were it a touch, this alone
        // would promote it to most-recent and evict a filler instead.
        for _ in 0..<3 {
            _ = state.nextEligibleDate(key: "oldest", policy: policy)
        }
        state.recordSuccess(key: "newcomer", at: start.addingTimeInterval(Double(limit)))

        let revisitsOldest = state.shouldRequest(
            key: "oldest",
            reason: .focus,
            at: start.addingTimeInterval(Double(limit) + 1),
            policy: policy
        )
        #expect(revisitsOldest, "the oldest subject was still the one evicted")
    }
}
