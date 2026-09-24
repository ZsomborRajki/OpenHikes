//
//  RouteBorderTests.swift
//  OpenHikesTests
//
//  The pieces of the border that are arithmetic rather than drawing: how
//  thick it is at each end of the width slider, what a pick from the colour
//  picker stores, and how a dash is lengthened to be outlined. Whether the map actually puts the ink down is
//  `DirectionalPolylineRendererTests+Border`.
//

import CoreGraphics
@testable import OpenHikes
import Testing

@Suite("Route border")
struct RouteBorderTests {
    @Test("the border grows with the line and never drops under a point", arguments: [
        (1.0, 1.0),
        (3.0, 1.0),
        (6.0, 2.0),
        (12.0, 4.0),
    ])
    func widthFollowsTheLine(lineWidth: Double, expected: Double) {
        #expect(RouteBorder.width(forLineWidth: lineWidth) == expected)
    }

    // MARK: Picking a colour

    @Test("a colour picked onto no border arrives opaque")
    func firstPickIsOpaque() {
        #expect(RouteBorder.pickedHex("#FF000000", over: RouteBorder.noneHex) == "#FF0000FF")
    }

    /// Black at zero opacity is what a transparent black default would have
    /// been, so a first pick of black compared equal to it and was dropped —
    /// the likeliest border colour of all, and the tap looked ignored.
    @Test("black picked onto a hike that never had a border arrives opaque")
    func firstPickOfBlackIsOpaque() {
        #expect(RouteBorder.pickedHex("#00000000", over: RouteBorder.noneHex) == "#000000FF")
    }

    @Test("a different colour picked onto a faded-out border arrives opaque")
    func newColourOverFadedIsOpaque() {
        #expect(RouteBorder.pickedHex("#FFFFFF00", over: "#FF000000") == "#FFFFFFFF")
    }

    @Test("taking the opacity to zero is how a border is removed, so it stays zero")
    func fadingOutIsKept() {
        #expect(RouteBorder.pickedHex("#FF000000", over: "#FF000080") == "#FF000000")
        #expect(RouteBorder.pickedHex("#FF000000", over: "#FF000000") == "#FF000000")
    }

    @Test("a border that is showing takes whatever the picker says", arguments: [
        ("#00FF0080", "#FF0000FF"),
        ("#00FF00FF", "#FF000000"),
    ])
    func visiblePicksPassThrough(picked: String, current: String) {
        #expect(RouteBorder.pickedHex(picked, over: current) == picked)
    }

    // MARK: Dashes

    @Test("a butt-capped dash is lengthened by the border at each end, and the period kept")
    func buttDashesReachPastTheirEnds() {
        let dashes = RouteBorder.dashes(outlining: [18, 15], cap: .butt, borderWidth: 2)
        #expect(dashes.lengths == [22, 11])
        #expect(dashes.phase == 2)
    }

    @Test("a round-capped dash already grows with the stroke, so it is left alone")
    func roundDashesStand() {
        let dashes = RouteBorder.dashes(outlining: [0.1, 12], cap: .round, borderWidth: 2)
        #expect(dashes.lengths == [0.1, 12])
        #expect(dashes.phase == 0)
    }

    @Test("a gap narrower than the border keeps a sliver rather than going negative")
    func gapNeverCloses() throws {
        let dashes = RouteBorder.dashes(outlining: [6, 3], cap: .butt, borderWidth: 2)
        let gap = try #require(dashes.lengths.last)
        #expect(gap > 0)
    }

    @Test("an unbroken line has no dashes to outline")
    func solidHasNoDashes() {
        #expect(RouteBorder.dashes(outlining: [], cap: .butt, borderWidth: 2).lengths.isEmpty)
    }

    @Test("a new hike stores no border")
    func newHikeHasNoBorder() {
        #expect(Hike(title: "Loop", distanceMeters: 1).routeBorderHex == RouteBorder.noneHex)
    }
}
