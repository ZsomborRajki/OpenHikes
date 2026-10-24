//
//  WatchTrailBudgetTests.swift
//  OpenHikesSharedTests
//
//  Which of a route's points and pauses cross to the watch (#1023). Both ends
//  of every pause used to cross with no cap, so a GPX file of thousands of
//  `<trkseg>`s sent thousands of points past the budget and drew thousands of
//  polylines on the watch.
//

import Foundation
@testable import OpenHikesShared
import Testing

// swiftlint:disable no_magic_numbers

@Suite("Watch trail budget")
struct WatchTrailBudgetTests {
    private typealias Pause = WatchTrailPackage.RoutePause

    /// A pause at every `every`th point of a `count`-point route, each with
    /// the gap `gap` gives it.
    private static func pauses(count: Int, every: Int, gap: (Int) -> Double = { _ in 10 }) -> [Pause] {
        stride(from: every, to: count, by: every).map { Pause(resumedAt: $0, gapMeters: gap($0)) }
    }

    @Test("a route with no pause is the widget's stride at the full budget")
    func noPauseIsThePlainStride() {
        let kept = WatchTrailPackage.keptPoints(count: 5000, pauses: [])

        #expect(kept.routeIndices == decimatedIndices(count: 5000, maxPoints: WatchTrailPackage.pointBudget))
        #expect(kept.pauseIndices.isEmpty)
    }

    @Test("a short route crosses whole, every pause with it")
    func shortRouteIsUntouched() {
        let kept = WatchTrailPackage.keptPoints(count: 10, pauses: Self.pauses(count: 10, every: 3))

        #expect(kept.routeIndices == Array(0..<10))
        #expect(kept.pauseIndices == [3, 6, 9])
    }

    /// The issue's own figures: 2,000 segments of ten points kept 4,648.
    @Test("a route with thousands of pauses stays within the point budget")
    func manyPausesStayWithinBudget() {
        let kept = WatchTrailPackage.keptPoints(count: 20_000, pauses: Self.pauses(count: 20_000, every: 10))

        #expect(kept.routeIndices.count <= WatchTrailPackage.pointBudget)
        #expect(kept.pauseIndices.count == WatchTrailPackage.pauseBudget)
        #expect(kept.routeIndices.first == 0)
        #expect(kept.routeIndices.last == 19_999)
    }

    @Test(
        "the kept count never passes the budget, however many pauses there are",
        arguments: [0, 1, 10, 49, 50, 51, 399, 400, 401, 799, 5000]
    )
    func neverPastTheBudget(pauseCount: Int) {
        let count = 6000
        let pauses = (0..<pauseCount).map { Pause(resumedAt: 1 + $0, gapMeters: Double($0)) }
        let kept = WatchTrailPackage.keptPoints(count: count, pauses: pauses)

        #expect(kept.routeIndices.count <= WatchTrailPackage.pointBudget)
        #expect(kept.pauseIndices.count == min(pauseCount, WatchTrailPackage.pauseBudget))
        #expect(kept.routeIndices == kept.routeIndices.sorted())
        #expect(Set(kept.routeIndices).count == kept.routeIndices.count)
    }

    @Test("every kept pause is exactly one leg of the route")
    func eachKeptPauseIsOneLeg() {
        let pauses = Self.pauses(count: 20_000, every: 7) { Double($0 % 97) }
        let kept = WatchTrailPackage.keptPoints(count: 20_000, pauses: pauses)
        let resumes = Set(pauses.map(\.resumedAt))

        for position in kept.pauseIndices {
            #expect(position > 0)
            let after = kept.routeIndices[position]
            #expect(kept.routeIndices[position - 1] == after - 1)
            #expect(resumes.contains(after))
        }
    }

    /// A folded pause whose resume point the stride happens to keep is
    /// trail now, not a pause: named as one, it would be a pause leg with
    /// walking folded into it.
    @Test("a folded pause is never named, even where the stride keeps its point")
    func foldedPausesAreNotNamed() throws {
        let pauses = Self.pauses(count: 20_000, every: 10)
        let kept = WatchTrailPackage.keptPoints(count: 20_000, pauses: pauses)
        let named = Set(kept.pauseIndices.map { kept.routeIndices[$0] })
        let strayResumes = kept.routeIndices.filter { $0.isMultiple(of: 10) && $0 > 0 && !named.contains($0) }

        try #require(!strayResumes.isEmpty, "the stride kept no folded resume point, so this proves nothing")
        #expect(named.count == WatchTrailPackage.pauseBudget)
    }

    @Test("past the cap, the longest breaks are kept and the shortest folded into the line")
    func longestBreaksAreKept() {
        let drives: Set<Int> = [70, 9000, 19_990]
        let pauses = Self.pauses(count: 20_000, every: 10) { drives.contains($0) ? 1500 : 12 }
        let kept = WatchTrailPackage.keptPoints(count: 20_000, pauses: pauses, pauseBudget: 3)

        #expect(Set(kept.pauseIndices.map { kept.routeIndices[$0] }) == drives)
    }

    @Test("ties go to the earlier break, so the same route packages the same way")
    func tiesAreDeterministic() {
        let pauses = Self.pauses(count: 1000, every: 10)
        let kept = WatchTrailPackage.keptPoints(count: 1000, pauses: pauses.reversed(), pauseBudget: 4)

        #expect(kept.pauseIndices.map { kept.routeIndices[$0] } == [10, 20, 30, 40])
    }

    @Test("adjacent pauses share their middle point, and each is still one leg")
    func adjacentPausesShareAPoint() {
        let pauses = [Pause(resumedAt: 2500, gapMeters: 500), Pause(resumedAt: 2501, gapMeters: 500)]
        let kept = WatchTrailPackage.keptPoints(count: 5000, pauses: pauses)

        let named = kept.pauseIndices.map { kept.routeIndices[$0] }
        #expect(named == [2500, 2501])
        #expect(kept.pauseIndices[1] == kept.pauseIndices[0] + 1)
        #expect(kept.routeIndices[kept.pauseIndices[0] - 1] == 2499)
    }

    @Test("a break that cannot be measured is kept only after every one that can")
    func unmeasurableBreaksGoLast() {
        let gaps: [Double] = [.nan, 40, .infinity, 30, .nan, 20]
        let pauses = gaps.enumerated().map { Pause(resumedAt: 100 * ($0.offset + 1), gapMeters: $0.element) }
        let kept = WatchTrailPackage.keptPoints(count: 5000, pauses: pauses, pauseBudget: 3)

        #expect(kept.pauseIndices.map { kept.routeIndices[$0] } == [200, 400, 600])
    }

    @Test("a pause the route cannot hold is ignored, and a repeat counts once")
    func invalidPausesAreIgnored() {
        let pauses = [0, -3, 5, 5, 10, 42].map { Pause(resumedAt: $0, gapMeters: 100) }
        let kept = WatchTrailPackage.keptPoints(count: 10, pauses: pauses)

        #expect(kept.pauseIndices.map { kept.routeIndices[$0] } == [5])
    }

    @Test("a budget too small for its pauses still leaves the line its two ends")
    func tinyBudgetKeepsTheEnds() {
        let kept = WatchTrailPackage.keptPoints(
            count: 100,
            pauses: Self.pauses(count: 100, every: 5),
            pointBudget: 6
        )

        #expect(kept.routeIndices.count <= 6)
        #expect(kept.routeIndices.first == 0)
        #expect(kept.routeIndices.last == 99)
        #expect(kept.pauseIndices.count == 2)
    }

    /// What the watch's map draws from a kept route: a casing and a line per
    /// walked run, and one line per paused stretch.
    @Test("the watch's map draws a bounded number of lines")
    func mapLinesAreBounded() {
        let count = 20_000
        let kept = WatchTrailPackage.keptPoints(count: count, pauses: Self.pauses(count: count, every: 10))
        let package = WatchTrailPackage(
            hikeID: UUID(),
            title: "Segmented",
            tintHex: "#1B7F3B",
            totalDistanceMeters: 20_000,
            points: kept.routeIndices.map { WatchTrailPoint(latitude: 0, longitude: Double($0) * 0.0001) },
            pauseIndices: kept.pauseIndices
        )

        let lines = 2 * package.walkedRuns.count + package.pausedStretches.count
        #expect(lines <= 3 * WatchTrailPackage.pauseBudget + 2)
        #expect(package.pausedLegs.count == WatchTrailPackage.pauseBudget)
    }
}

// swiftlint:enable no_magic_numbers
