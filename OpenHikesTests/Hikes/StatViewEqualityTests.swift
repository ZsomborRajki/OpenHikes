//
//  StatViewEqualityTests.swift
//  OpenHikesTests
//
//  `StatFigure` and `StatRow` compare by what they draw, so a pass of the hike
//  detail that changes none of a figure's words skips its body. A render trace
//  of the walk suite measured all three figures and all nine rows running on
//  every such pass, words unchanged. What is pinned here is the comparison:
//  the same words are the same view, and a changed caption, value or spoken
//  label is not.
//

@testable import OpenHikes
import SwiftUI
import Testing

@MainActor
@Suite("Stat view equality")
struct StatViewEqualityTests {
    private static let speed = Stat("Overall Avg Speed", "4.2 km/h", spokenAs: "Overall Average Speed")

    @Test("a figure built twice from the same stat is the same figure")
    func figuresCompareByTheirWords() {
        let built = StatFigure(Self.speed)
        let builtAgain = StatFigure(Self.speed)
        #expect(built == builtAgain)
        #expect(StatFigure(Self.speed) != StatFigure(label: "Overall Avg Speed", value: "4.2 km/h"))
        #expect(StatFigure(Self.speed) != StatFigure(Stat("Overall Avg Speed", "4.3 km/h")))
    }

    @Test("a row built twice from the same stat is the same row")
    func rowsCompareByTheirWords() {
        let built = StatRow(Self.speed)
        let builtAgain = StatRow(Self.speed)
        #expect(built == builtAgain)
        let keyed = StatRow(label: "Current Speed", value: "3 km/h")
        let keyedAgain = StatRow(label: "Current Speed", value: "3 km/h")
        #expect(keyed == keyedAgain)
        #expect(StatRow(label: "Current Speed", value: "3 km/h") != StatRow(label: "Current Speed", value: "4 km/h"))
        #expect(StatRow(verbatim: "Current Speed", value: "3 km/h") != StatRow(label: "Current Speed", value: "3 km/h"))
        #expect(StatRow(Self.speed) != StatRow(Stat("Overall Avg Speed", "4.2 km/h")))
    }
}
