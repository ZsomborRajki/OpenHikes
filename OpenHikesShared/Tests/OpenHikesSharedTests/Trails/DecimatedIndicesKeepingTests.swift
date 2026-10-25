//
//  DecimatedIndicesKeepingTests.swift
//  OpenHikesSharedTests
//
//  The stride around points a line must keep, which the widget's line, the
//  watch's package and the heights asked of Stadia share (#1084). Each
//  writer's own choice of points is pinned in its own suite.
//

@testable import OpenHikesShared
import Testing

// swiftlint:disable no_magic_numbers

@Suite("Decimated indices keeping required points")
struct DecimatedIndicesKeepingTests {
    @Test("nothing required is the plain stride", arguments: [0, 1, 9, 10, 11, 62, 2000])
    func nothingRequiredIsThePlainStride(count: Int) {
        #expect(decimatedIndices(count: count, maxPoints: 10, keeping: [])
            == decimatedIndices(count: count, maxPoints: 10))
    }

    @Test("an empty line, a single point and a line of exactly the budget come back whole")
    func shortLinesAreWhole() {
        #expect(decimatedIndices(count: 0, maxPoints: 10, keeping: []).isEmpty)
        #expect(decimatedIndices(count: 1, maxPoints: 10, keeping: [0]) == [0])
        #expect(decimatedIndices(count: 10, maxPoints: 10, keeping: [3, 4]) == Array(0..<10))
    }

    @Test("a longer line is exactly the budget, every required point and both ends among it")
    func longerLineIsTheBudget() {
        let required: Set<Int> = [7, 8, 500, 501, 502, 1998]
        let kept = decimatedIndices(count: 2000, maxPoints: 180, keeping: required)

        #expect(kept.count == 180)
        #expect(kept == kept.sorted() && Set(kept).count == kept.count, "ascending, once each")
        #expect(required.isSubset(of: kept))
        #expect(kept.first == 0 && kept.last == 1999)
    }

    @Test("the stride is taken over the points that are not required")
    func strideOverTheOthers() {
        #expect(decimatedIndices(count: 23, maxPoints: 10, keeping: [8, 9]) == [0, 3, 6, 8, 9, 11, 13, 16, 19, 22])
        #expect(decimatedIndices(count: 30, maxPoints: 10, keeping: [0, 1, 28, 29])
            == [0, 1, 2, 7, 12, 17, 22, 27, 28, 29])
    }

    @Test("less than two remaining stride points keeps the line whole", arguments: [0, 1, 2, 3])
    func insufficientRemainingBudget(maxPoints: Int) {
        #expect(decimatedIndices(count: 10, maxPoints: maxPoints, keeping: [3, 4]) == Array(0..<10))
    }
}

// swiftlint:enable no_magic_numbers
