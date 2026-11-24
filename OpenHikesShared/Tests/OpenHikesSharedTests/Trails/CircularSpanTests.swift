//
//  CircularSpanTests.swift
//  OpenHikesSharedTests
//
//  The arc both of the app's antimeridian-aware boxes are measured with:
//  `TileBoundingBox` in degrees and `TrailBasemap` in unit x. Each case is
//  one a route gives: a single fix, a fix repeated, an ordinary walk, a walk
//  across ±180°, and gaps of equal width, where only the tie rule says which
//  way round the route goes.
//

import Foundation
@testable import OpenHikesShared
import Testing

@Suite("Circular span")
struct CircularSpanTests {
    @Test("no positions have no arc")
    func emptyHasNoArc() {
        #expect(CircularSpan(enclosing: [], period: 360) == nil)
    }

    @Test("a single position is an arc of no length that starts on it")
    func singlePosition() throws {
        let arc = try #require(CircularSpan(enclosing: [12.5], period: 360))

        #expect(arc.start == 12.5)
        #expect(arc.length == 0)
    }

    @Test("a position repeated is still an arc of no length")
    func repeatedPosition() throws {
        let arc = try #require(CircularSpan(enclosing: [12.5, 12.5, 12.5], period: 360))

        #expect(arc.start == 12.5)
        #expect(arc.length == 0)
    }

    @Test("an ordinary walk runs from its westmost position, in any order")
    func ordinaryWalk() throws {
        let arc = try #require(CircularSpan(enclosing: [11, 10, 12.5, 10], period: 360))

        #expect(arc.start == 10)
        #expect(arc.length == 2.5)
    }

    /// The case a min/max gets wrong: a walk either side of ±180° is a few
    /// degrees wide, not most of the world.
    @Test("a walk across the antimeridian starts east of it and wraps")
    func wrappedWalk() throws {
        let arc = try #require(CircularSpan(enclosing: [179, -179.5, 178.5], period: 360))

        #expect(arc.start == 178.5)
        #expect(arc.length == 2)
    }

    @Test("unit x wraps at 1 the way degrees wrap at 360")
    func unitXWraps() throws {
        let arc = try #require(CircularSpan(enclosing: [0.125, 0.75], period: 1))

        #expect(arc.start == 0.75)
        #expect(arc.length == 0.375)
    }

    /// Three gaps of 120°: the one through the wrap is weighed first and is
    /// not beaten by one merely as wide, so the arc starts at the westmost
    /// position, as a plain min/max would have it.
    @Test("a tie with the gap through the wrap keeps the wrap")
    func tieKeepsTheWrap() throws {
        let arc = try #require(CircularSpan(enclosing: [120, -120, 0], period: 360))

        #expect(arc.start == -120)
        #expect(arc.length == 240)
    }

    /// Two interior gaps of 160°, both wider than the wrap's 40°: the first
    /// one found going east wins, so the arc starts at its east end.
    @Test("a tie between two inner gaps keeps the westmost")
    func tieKeepsTheWestmostGap() throws {
        let arc = try #require(CircularSpan(enclosing: [150, -170, -10], period: 360))

        #expect(arc.start == -10)
        #expect(arc.length == 200)
    }

    /// The start is a position given, never a gap added back to the one
    /// before it, so a value with no exact binary sum comes back unchanged.
    @Test("the start is a position given, unrounded")
    func startIsAPositionGiven() throws {
        let east = 179.99999999
        let arc = try #require(CircularSpan(enclosing: [-179.3, east, 179.7], period: 360))

        #expect(arc.start == 179.7)
        let throughEast = try #require(CircularSpan(enclosing: [east, -170.1, -160.2], period: 360))
        #expect(throughEast.start == east)
    }
}
