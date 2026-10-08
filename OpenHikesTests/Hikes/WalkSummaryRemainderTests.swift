//
//  WalkSummaryRemainderTests.swift
//  OpenHikesTests
//
//  The line under a walk summary's bar says how much of the trail was left,
//  and only when something was: a walk that covered all of it printed
//  "0 m of the trail not hiked" under *100% Completed*.
//

@testable import OpenHikes
import Testing

@Suite("Walk summary remainder")
struct WalkSummaryRemainderTests {
    @Test("a walk that covered the whole trail has no remainder to print")
    func wholeTrailLeavesNothing() {
        #expect(WalkSummaryView.leftUnhiked(0) == nil)
    }

    @Test("less than a metre is nothing, since it would print as zero")
    func underAMetreLeavesNothing() {
        #expect(WalkSummaryView.leftUnhiked(0.6) == nil)
    }

    @Test("a stretch the walk missed is printed as it is")
    func missedStretchIsKept() {
        #expect(WalkSummaryView.leftUnhiked(4700) == 4700)
        #expect(WalkSummaryView.leftUnhiked(1) == 1)
    }
}
