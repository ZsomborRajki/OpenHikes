//
//  WatchTrailKeptPointsPinTests.swift
//  OpenHikesSharedTests
//
//  Exactly which points cross to the watch, and which of them a kept pause
//  resumed on, for small routes whose answers can be read whole (#1084). The
//  fill around the kept pauses' ends is the helper the widget and the heights
//  asked of Stadia share; these pin what the watch's policy made of it before
//  that change, index by index. The budget's argument is in
//  `WatchTrailBudgetTests`.
//

@testable import OpenHikesShared
import Testing

// swiftlint:disable no_magic_numbers

@Suite("Watch trail kept points, pinned")
struct WatchTrailKeptPointsPinTests {
    /// The break across each leg, in metres: the leg before the pause at 20
    /// is the longest, then the one before 30, then the one before 10.
    private static let gaps: [Int: Double] = [9: 5, 19: 50, 29: 20]

    private static func kept(
        count: Int,
        pauses: [Int] = [],
        pointBudget: Int = 10,
        pauseBudget: Int = WatchTrailPackage.pauseBudget
    ) -> WatchTrailPackage.KeptPoints {
        WatchTrailPackage.keptPoints(
            of: TrailRuns(pointCount: count, pauseIndices: pauses),
            gapMeters: { gaps[$0] ?? 1 },
            pointBudget: pointBudget,
            pauseBudget: pauseBudget
        )
    }

    @Test("an empty route, a single point and a route of exactly the budget cross whole")
    func shortRoutesAreWhole() {
        #expect(Self.kept(count: 0) == .init(routeIndices: [], pauseIndices: []))
        #expect(Self.kept(count: 1) == .init(routeIndices: [0], pauseIndices: []))
        #expect(Self.kept(count: 10, pauses: [3, 6]) == .init(routeIndices: Array(0..<10), pauseIndices: [3, 6]))
    }

    @Test("a route one past the budget, with no pause, is the plain stride")
    func onePastTheBudget() {
        #expect(Self.kept(count: 11).routeIndices == [0, 1, 2, 3, 4, 6, 7, 8, 9, 10])
    }

    /// Fifteen points over 62 put one of the stride's positions on a half,
    /// 30.5, which the stride's rounding sends to 30.
    @Test("the stride's rounding of a position that falls on a half")
    func strideOnAHalf() {
        #expect(Self.kept(count: 62, pointBudget: 15).routeIndices
            == [0, 4, 9, 13, 17, 22, 26, 30, 35, 39, 44, 48, 52, 57, 61])
    }

    @Test("adjacent pauses share an end, and the stride fills the rest")
    func adjacentPauses() {
        #expect(Self.kept(count: 23, pauses: [5, 6])
            == .init(routeIndices: [0, 3, 4, 5, 6, 9, 13, 16, 19, 22], pauseIndices: [3, 4]))
    }

    @Test("every pause crosses while the budget affords it")
    func everyPauseCrosses() {
        #expect(Self.kept(count: 40, pauses: [10, 20, 30])
            == .init(routeIndices: [0, 9, 10, 13, 19, 20, 26, 29, 30, 39], pauseIndices: [2, 5, 8]))
        #expect(Self.kept(count: 62, pauses: [21], pointBudget: 16)
            == .init(routeIndices: [0, 5, 9, 14, 18, 20, 21, 25, 29, 34, 38, 43, 47, 52, 56, 61], pauseIndices: [6]))
    }

    @Test("past the pause budget the longest breaks cross, and the shortest is left to the stride")
    func longestBreaksCross() {
        #expect(Self.kept(count: 40, pauses: [10, 20, 30], pauseBudget: 2)
            == .init(routeIndices: [0, 7, 14, 19, 20, 23, 29, 30, 32, 39], pauseIndices: [4, 7]))
    }

    @Test("a budget of two or less still keeps the route's two ends", arguments: [0, 1, 2])
    func budgetAtMostTwo(pointBudget: Int) {
        #expect(Self.kept(count: 40, pointBudget: pointBudget) == .init(routeIndices: [0, 39], pauseIndices: []))
    }
}

// swiftlint:enable no_magic_numbers
