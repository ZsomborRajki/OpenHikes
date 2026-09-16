//
//  MergedCommunityTransportTests+Curated.swift
//  OpenHikesTests
//
//  What the curated half costs, and what it says when OpenStreetMap will not
//  answer.
//
//  An extension of `MergedCommunityTransportTests` in a file of its own rather
//  than a suite of its own, for the reason `CloudKitCommunityTransport+Reviewing`
//  is split from its sibling: this is the same type under test with the same
//  two stubs behind it, and the file it came from is at the length limit. What
//  separates the two halves is the question being asked — that one is about the
//  merge, this one is about the *cost* of asking and the sentence a refusal
//  turns into, neither of which is visible in the rows.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import Testing

// MARK: - Overpass is asked only when the question asks for it

extension MergedCommunityTransportTests {
    /// The rule this scope exists for, asserted where it is decided. It cannot
    /// be seen in the rows — a published-only answer and a curated one with
    /// nothing near the centre are the same list — so the claim is that the
    /// source was never spoken to at all.
    @Test("a published-only question never reaches Overpass")
    func publishedOnlyLeavesTheCuratedSourceQuiet() async throws {
        let merged = Self.merged(
            published: [Self.published("listing-a", metresNorth: Offset.near)],
            curated: [Self.trail(Relation.wimbach, named: "Wimbachgries", metresNorth: Offset.nearest)]
        )

        let answer = try await Self.answer(merged, scope: .publishedOnly)

        #expect(answer.listings.map(\.id) == ["listing-a"])
        #expect(answer.curatedOutage == nil, "nothing was asked, so there is nothing to report")
        #expect(merged.overpass.recording.isQuiet)
        #expect(merged.cloudKit.recording.nearbyRequests.count == 1)
    }

    /// The same question with the scope the button asks with, so the test
    /// above is about the scope rather than about a fixture that had nothing
    /// in it.
    @Test("the curated question reaches both halves")
    func curatedScopeAsksBoth() async throws {
        let merged = Self.merged(
            published: [Self.published("listing-a", metresNorth: Offset.near)],
            curated: [Self.trail(Relation.wimbach, named: "Wimbachgries", metresNorth: Offset.nearest)]
        )

        let answer = try await Self.answer(merged, scope: .withCuratedTrails)

        #expect(answer.listings.count == 2)
        #expect(!merged.overpass.recording.isQuiet)
    }
}

// MARK: - A refused curated half is reported, not thrown

extension MergedCommunityTransportTests {
    /// The failure this reporting exists against: a `429` used to reach the
    /// log and nowhere else, so a rate-limited hiker saw a list with no trails
    /// in it and nothing to tell that apart from an area with none.
    @Test("a rate-limited listing pass is carried back beside the rows")
    func aRateLimitedListingPassIsReported() async throws {
        let merged = Self.merged(
            published: [Self.published("listing-a", metresNorth: Offset.near)]
        )
        merged.overpass.nearbyResult = .failure(.rateLimited(retryAfter: 60))

        let answer = try await Self.answer(merged)

        #expect(answer.curatedOutage == .rateLimited(retryAfter: 60))
        #expect(
            answer.listings.map(\.id) == ["listing-a"],
            "one source failing is still not the answer failing"
        )
    }

    /// Everything else Overpass can do, which is the state a hiker with no
    /// signal is in. Still not a failure of the request: the published half
    /// answered.
    @Test("any other curated failure is reported as unavailable")
    func anotherCuratedFailureIsReported() async throws {
        let merged = Self.merged(
            published: [Self.published("listing-a", metresNorth: Offset.near)]
        )
        merged.overpass.nearbyResult = .failure(.server(statusCode: 504))

        let answer = try await Self.answer(merged)

        #expect(answer.curatedOutage == .unavailable)
        #expect(answer.listings.map(\.id) == ["listing-a"])
    }

    /// The happy answer says nothing, including for an area that genuinely has
    /// no waymarked routes in it — which is most of the world, and is not
    /// something to caption a button with.
    @Test("a curated half that answered reports no outage")
    func aGoodCuratedHalfReportsNothing() async throws {
        let merged = Self.merged(
            published: [Self.published("listing-a", metresNorth: Offset.near)]
        )

        let answer = try await Self.answer(merged)

        #expect(answer.curatedOutage == nil)
    }

    /// What a refused search draws instead of nothing: the routes this device
    /// downloaded the last time it was asked about somewhere near here.
    @Test("a refused search falls back to the routes already on the device")
    func aRefusedSearchDrawsWhatIsAlreadyHere() async throws {
        let merged = Self.merged(
            published: [Self.published("listing-a", metresNorth: Offset.far)]
        )
        merged.overpass.nearbyResult = .failure(.rateLimited(retryAfter: 60))
        merged.overpass.storedTrails = [
            Self.trail(Relation.wimbach, named: "Wimbachgries", metresNorth: Offset.nearest),
        ]

        let answer = try await Self.answer(merged)

        #expect(answer.listings.count == 2, "the stored route stands beside the published hike")
        #expect(
            merged.overpass.recording.cacheReads.count == 1,
            "the device's own routes are read once, for the area that was refused"
        )
    }

    /// And it is still an outage. The rows are whatever happens to be on the
    /// device — there is no record of whether that is the area's trails or
    /// four of them — so the caption under the button stays up.
    @Test("falling back does not clear the outage")
    func fallingBackKeepsTheOutage() async throws {
        let merged = Self.merged()
        merged.overpass.nearbyResult = .failure(.rateLimited(retryAfter: 60))
        merged.overpass.storedTrails = [
            Self.trail(Relation.wimbach, named: "Wimbachgries", metresNorth: Offset.nearest),
        ]

        let answer = try await Self.answer(merged)

        #expect(answer.curatedOutage == .rateLimited(retryAfter: 60))
        #expect(!answer.listings.isEmpty)
    }

    /// A search that was never refused does not read the device's own routes,
    /// because Overpass answered — and the answer is the answer.
    @Test("a search that worked never falls back")
    func aGoodSearchDoesNotFallBack() async throws {
        let merged = Self.merged(
            curated: [Self.trail(Relation.almbach, named: "Almbachklamm", metresNorth: Offset.near)]
        )
        merged.overpass.storedTrails = [
            Self.trail(Relation.wimbach, named: "Wimbachgries", metresNorth: Offset.nearest),
        ]

        let answer = try await Self.answer(merged)

        #expect(answer.listings.count == 1)
        #expect(merged.overpass.recording.cacheReads.isEmpty)
    }

    /// A published-only question has nothing to fall back *from*: nothing was
    /// asked of Overpass, so nothing was refused.
    @Test("a published-only question never reads the device's routes either")
    func publishedOnlyDoesNotFallBack() async throws {
        let merged = Self.merged(
            published: [Self.published("listing-a", metresNorth: Offset.near)]
        )
        merged.overpass.storedTrails = [
            Self.trail(Relation.wimbach, named: "Wimbachgries", metresNorth: Offset.nearest),
        ]

        let answer = try await Self.answer(merged, scope: .publishedOnly)

        #expect(answer.listings.map(\.id) == ["listing-a"])
        #expect(merged.overpass.recording.cacheReads.isEmpty)
    }
}
