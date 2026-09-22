//
//  TrailLegMemoTests.swift
//  OpenHikesTests
//
//  What the drawing remembers about its own legs.
//
//  Two rules, and both of them are invisible from the screen until they are
//  wrong. **Only settled answers are kept** — a refusal that were remembered
//  would make *Try Again* answer instantly with the failure it was asked to
//  retry — and **the memo is bounded**, or a long editing session is a drawing
//  that grows in memory for as long as it is open.
//
//  ``TrailDraftHistoryTests`` asserts what this is for, from the draft's side.
//

import Foundation
@testable import OpenHikes
import Testing

@Suite("Trail leg memo")
struct TrailLegMemoTests {
    private static func ends(_ latitude: Double) -> TrailLegEnds {
        TrailLegEnds(
            start: RouteCoordinate(latitude: latitude, longitude: 12.83),
            end: RouteCoordinate(latitude: latitude + 0.001, longitude: 12.83)
        )
    }

    private static func leg(_ latitude: Double, _ snap: TrailLegSnap) -> TrailLeg {
        let ends = ends(latitude)
        return TrailLeg(
            id: UUID(),
            ends: ends,
            coordinates: ends.straightCoordinates,
            distanceMeters: ends.straightDistanceMeters,
            snap: snap
        )
    }

    @Test("a settled leg is remembered and comes back retargeted")
    func remembersASettledLeg() throws {
        var memo = TrailLegMemo()
        let leg = Self.leg(47.71, .snapped)
        memo.remember(leg)

        let arriving = UUID()
        let recalled = try #require(memo.leg(leg.ends, arrivingAt: arriving))

        #expect(recalled.snap == .snapped)
        #expect(recalled.coordinates == leg.coordinates)
        // The one thing about a remembered leg that is no longer true: which
        // waypoint it arrives at is a fact about the list it is in now.
        #expect(recalled.id == arriving)
    }

    @Test("an answer that there is nothing to follow is remembered too")
    func remembersAGap() {
        var memo = TrailLegMemo()
        let leg = Self.leg(47.71, .unmapped(.noPathBetween))
        memo.remember(leg)

        #expect(memo.leg(leg.ends, arrivingAt: UUID())?.snap == .unmapped(.noPathBetween))
    }

    /// The rule that keeps *Try Again* working: a refusal is a failure rather
    /// than an answer, and remembering it would hand the same failure straight
    /// back to the hiker who asked for another go.
    @Test("a refusal is not remembered")
    func doesNotRememberARefusal() {
        var memo = TrailLegMemo()
        let leg = Self.leg(47.71, .refused(.busy))
        memo.remember(leg)

        #expect(memo.isEmpty)
        #expect(memo.leg(leg.ends, arrivingAt: UUID()) == nil)
    }

    @Test("a leg nobody has asked about is not remembered")
    func doesNotRememberTheUnasked() {
        var memo = TrailLegMemo()
        memo.remember([Self.leg(47.71, .freehand), Self.leg(47.72, .routing)])

        #expect(memo.isEmpty)
    }

    @Test("remembering the same leg twice keeps one slot")
    func rememberingTwiceKeepsOneSlot() {
        var memo = TrailLegMemo()
        memo.remember(Self.leg(47.71, .snapped))
        memo.remember(Self.leg(47.71, .unmapped(.noPathBetween)))

        #expect(memo.count == 1)
        #expect(
            memo.leg(Self.ends(47.71), arrivingAt: UUID())?.snap == .unmapped(.noPathBetween),
            "the later answer is the one that stands"
        )
    }

    /// Oldest first, so a drawing that has been rearranged for a long time
    /// stops growing rather than keeping every adjacency it ever had.
    @Test("the memo is bounded, and drops the oldest")
    func theMemoIsBounded() {
        var memo = TrailLegMemo()
        let first = Self.leg(47.0, .snapped)
        memo.remember(first)
        for step in 1...TrailLegMemo.capacity {
            memo.remember(Self.leg(47.0 + Double(step) / 100, .snapped))
        }

        #expect(memo.count == TrailLegMemo.capacity)
        #expect(memo.leg(first.ends, arrivingAt: UUID()) == nil)
    }

    /// The routers' own caches, which live as long as the app does: one per
    /// travel mode, so an unbounded one grows with every leg ever asked.
    @Test("a router's answers are bounded the same way, oldest first")
    func theAnswerCacheIsBounded() {
        var cache = TrailLegAnswerCache()
        let first = Self.ends(47.0)
        cache.store(.straight(along: first, .snapped), for: first)
        cache.store(.straight(along: first, .unmapped(.noPathBetween)), for: first)
        #expect(cache.count == 1, "answering the same leg again keeps one slot")
        #expect(cache[first]?.snap == .unmapped(.noPathBetween))

        for step in 1...TrailLegMemo.capacity {
            let ends = Self.ends(47.0 + Double(step) / 100)
            cache.store(.straight(along: ends, .snapped), for: ends)
        }

        #expect(cache.count == TrailLegMemo.capacity)
        #expect(cache[first] == nil)
        #expect(cache[Self.ends(47.0 + Double(TrailLegMemo.capacity) / 100)] != nil)
    }
}
