//
//  RouteChevronFieldTests.swift
//  OpenHikesTests
//
//  The rule that decides which direction chevrons survive where a route
//  covers its own ground, asserted directly rather than counted in pixels.
//
//  Three things have to hold at once, and they pull against each other. A
//  walk that comes home the way it went out must not draw two opposed
//  chevrons on every metre of the shared stretch — the complaint this exists
//  for. A route that merely *crosses* itself must keep both, because a
//  crossing is worth reading. And an ordinary line, straight or bending, must
//  come out exactly as it did before there was a rule at all: the fix is
//  worthless if it thins the chevrons of every other hike to buy it.
//
//  Distances here are plain numbers in a plane. The renderer's are map points
//  at a zoom scale, which is the same plane with a scale on it.
//

@testable import OpenHikes
import Testing

@Suite("Route chevron field")
struct RouteChevronFieldTests {
    /// Stand-ins for what `RouteChevronMetrics` hands the renderer: chevrons a
    /// spacing apart, a retrace clearance just under that spacing, and a much
    /// smaller footprint for two that genuinely cross.
    static let spacing: Double = 100
    static let retrace: Double = 75
    static let crossing: Double = 20

    static func field(cellSize: Double = max(retrace, crossing)) -> RouteChevronField {
        RouteChevronField(cellSize: cellSize)
    }

    /// Heading east unless told otherwise.
    static func chevron(x: Double, y: Double = 0, ux: Double = 1, uy: Double = 0) -> RouteChevron {
        RouteChevron(x: x, y: y, ux: ux, uy: uy)
    }

    @discardableResult static func claim(
        _ chevron: RouteChevron,
        in field: inout RouteChevronField
    ) -> Bool {
        field.claim(chevron, retrace: retrace, crossing: crossing)
    }

    // MARK: The stretch walked twice

    @Test("the way home over the way out draws nothing the way out did not")
    func reversedLegIsDropped() {
        var field = Self.field()
        Self.claim(Self.chevron(x: 0), in: &field)
        // Anywhere on the stretch is within half a spacing of an outbound
        // chevron, so no phase the return leg lands on can clear the rule.
        for offset in stride(from: -Self.spacing / 2, through: Self.spacing / 2, by: 10) {
            #expect(
                Self.claim(Self.chevron(x: offset, ux: -1), in: &field) == false,
                "a return chevron \(offset) along the shared stretch was drawn"
            )
        }
    }

    @Test("a second lap of a loop does not double the arrows")
    func repeatedLegIsDropped() {
        var field = Self.field()
        Self.claim(Self.chevron(x: 0), in: &field)
        #expect(Self.claim(Self.chevron(x: 30), in: &field) == false)
    }

    // MARK: The line everyone else is drawing

    @Test("chevrons a spacing apart along a straight line all survive")
    func straightLineKeepsEveryChevron() {
        var field = Self.field()
        for step in 0..<6 {
            #expect(
                Self.claim(Self.chevron(x: Double(step) * Self.spacing), in: &field),
                "chevron \(step) of a plain straight line was dropped"
            )
        }
    }

    /// A bend, not a switchback: the straight-line gap between two chevrons a
    /// spacing apart along a curve shortens as the path turns, and the rule
    /// has to stay clear of that until the turn is sharp enough to make the
    /// two collide anyway.
    @Test("a bending path keeps its chevrons")
    func bendKeepsBothChevrons() {
        var field = Self.field()
        let turned = (ux: 0.7071, uy: 0.7071)   // 45° on from due east
        Self.claim(Self.chevron(x: 0), in: &field)
        #expect(Self.claim(Self.chevron(x: 97, ux: turned.ux, uy: turned.uy), in: &field))
    }

    @Test("a route crossing itself keeps both chevrons")
    func crossingKeepsBothChevrons() {
        var field = Self.field()
        Self.claim(Self.chevron(x: 0), in: &field)
        // Far enough apart not to print on top of each other, but nowhere near
        // the clearance a retrace would be held to.
        #expect(Self.claim(Self.chevron(x: 30, ux: 0, uy: 1), in: &field))
    }

    @Test("two chevrons crossing on the same spot would overdraw, so one goes")
    func crossingOnTheSameSpotDropsOne() {
        var field = Self.field()
        Self.claim(Self.chevron(x: 0), in: &field)
        #expect(Self.claim(Self.chevron(x: 5, ux: 0, uy: 1), in: &field) == false)
    }

    // MARK: The bookkeeping

    /// A chevron that was dropped left no ink, so it must not go on to block a
    /// third one from ground nothing is actually drawn on.
    @Test("a dropped chevron does not claim the ground it never covered")
    func droppedChevronsDoNotBlock() {
        var field = Self.field()
        Self.claim(Self.chevron(x: 0), in: &field)
        #expect(Self.claim(Self.chevron(x: 60, ux: -1), in: &field) == false)
        // Conflicts with the dropped one at 60, but not with the drawn one at 0.
        #expect(Self.claim(Self.chevron(x: 110, ux: -1), in: &field))
    }

    /// The grid is a speed-up, not the rule: a field bucketed finer than the
    /// clearance it is asked about still has to look far enough out.
    @Test("a conflict beyond one bucket is still found")
    func searchReachesPastOneCell() {
        var field = Self.field(cellSize: 10)
        Self.claim(Self.chevron(x: 0), in: &field)
        #expect(Self.claim(Self.chevron(x: 60, ux: -1), in: &field) == false)
    }
}
