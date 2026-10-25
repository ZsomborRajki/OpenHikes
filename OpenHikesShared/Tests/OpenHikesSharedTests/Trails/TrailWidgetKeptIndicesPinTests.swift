//
//  TrailWidgetKeptIndicesPinTests.swift
//  OpenHikesSharedTests
//
//  Exactly which points the widget's line keeps, for small routes whose
//  answers can be read whole (#1084). The widget, the watch's package and the
//  heights asked of Stadia each keep a set of points they must and fill the
//  rest of a budget with the stride; the fill is one helper now, and these
//  pin what the widget's policy made of it before the change, index by index.
//  The bound and the shape at the real budget are `TrailWidgetPauseTests`'.
//

@testable import OpenHikesShared
import Testing

// swiftlint:disable no_magic_numbers

@Suite("Trail widget kept indices, pinned")
struct TrailWidgetKeptIndicesPinTests {
    private static func kept(count: Int, maxPoints: Int = 10, legs: [Int] = [], endBudget: Int = 6) -> [Int] {
        SharedTrailSnapshot.keptIndices(count: count, maxPoints: maxPoints, pausedLegs: legs, pauseEndBudget: endBudget)
    }

    @Test("an empty route, a single point and a route of exactly the budget are kept whole")
    func shortRoutesAreWhole() {
        #expect(Self.kept(count: 0).isEmpty)
        #expect(Self.kept(count: 1) == [0])
        #expect(Self.kept(count: 10, legs: [3]) == Array(0..<10))
    }

    @Test("a route one past the budget, with no pause, is the plain stride")
    func onePastTheBudget() {
        #expect(Self.kept(count: 11) == [0, 1, 2, 3, 4, 6, 7, 8, 9, 10])
    }

    /// Fifteen points over 62 put one of the stride's positions on a half,
    /// 30.5, which the stride's rounding sends to 30.
    @Test("the stride's rounding of a position that falls on a half")
    func strideOnAHalf() {
        #expect(Self.kept(count: 62, maxPoints: 15) == [0, 4, 9, 13, 17, 22, 26, 30, 35, 39, 44, 48, 52, 57, 61])
    }

    @Test("adjacent pauses share an end, and the stride fills the rest")
    func adjacentPauses() {
        #expect(Self.kept(count: 23, legs: [4, 5]) == [0, 3, 4, 5, 6, 9, 13, 16, 19, 22])
    }

    @Test("a pause past the end budget is left to the stride")
    func pausePastTheEndBudget() {
        #expect(Self.kept(count: 40, legs: [10, 20, 30], endBudget: 4) == [0, 7, 10, 11, 16, 20, 21, 25, 32, 39])
    }

    @Test("a pause on the first or last leg shares the route's own end")
    func pausesAtTheEnds() {
        #expect(Self.kept(count: 40, legs: [38]) == [0, 5, 11, 16, 21, 26, 32, 37, 38, 39])
        #expect(Self.kept(count: 30, legs: [0, 28]) == [0, 1, 2, 7, 12, 17, 22, 27, 28, 29])
        #expect(Self.kept(count: 62, maxPoints: 16, legs: [20])
            == [0, 5, 9, 14, 18, 20, 21, 25, 29, 34, 38, 43, 47, 52, 56, 61])
    }

    @Test("a budget of one point keeps everything, as the plain stride does")
    func budgetOfOne() {
        #expect(Self.kept(count: 5, maxPoints: 1) == [0, 1, 2, 3, 4])
    }
}

// swiftlint:enable no_magic_numbers
