//
//  RouteBorderTests.swift
//  OpenHikesTests
//
//  The two pieces of the border that are arithmetic rather than drawing: how
//  thick it is at each end of the width slider, and what a pick from the
//  colour picker stores. Whether the map actually puts the ink down is
//  `DirectionalPolylineRendererTests+Border`.
//

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

    @Test("a new hike stores no border")
    func newHikeHasNoBorder() {
        #expect(Hike(title: "Loop", distanceMeters: 1).routeBorderHex == RouteBorder.noneHex)
    }
}
