//
//  TotalsFigureRunsTests.swift
//  OpenHikesTests
//
//  *Totals* draws a figure's number large and its unit small, and finds the
//  two in the text a formatter wrote. So the cut has to hold for whatever a
//  formatter writes: a space or a period between thousands, a comma for a
//  decimal, a duration that is two numbers and two units, a unit written
//  against its number, and digits that are not 0 to 9.
//
//  Every string here is spelled out. The formatters' own output is asked
//  for only where the property does not depend on what it is: that the
//  pieces put back together are the figure, and that it has a number in it.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import Testing

@Suite("Totals figures, cut into number and unit")
struct TotalsFigureRunsTests {
    private typealias Run = TotalsFigureRuns.Run

    private static func number(_ text: String) -> TotalsFigureRuns.Run { Run(text: text, isUnit: false) }
    private static func unit(_ text: String) -> TotalsFigureRuns.Run { Run(text: text, isUnit: true) }

    @Test("a number and its unit are two pieces, the space between them the unit's")
    func numberAndUnit() {
        #expect(TotalsFigureRuns.runs(of: "614 km") == [Self.number("614"), Self.unit(" km")])
    }

    @Test(
        "whatever groups thousands or marks a decimal is part of the number",
        arguments: ["27 224 m", "27\u{202F}224 m", "27.224 m", "27,224 m", "27’224 m", "9,3 m", "9.3 m"]
    )
    func separators(figure: String) {
        let runs = TotalsFigureRuns.runs(of: figure)
        #expect(runs.count == 2)
        #expect(runs.first?.isUnit == false)
        #expect(runs.last == Self.unit(" m"))
    }

    @Test("a duration is two numbers, each with its unit")
    func duration() {
        #expect(
            TotalsFigureRuns.runs(of: "225h 45m")
                == [Self.number("225"), Self.unit("h "), Self.number("45"), Self.unit("m")]
        )
        #expect(
            TotalsFigureRuns.runs(of: "225 ч 45 мин")
                == [Self.number("225"), Self.unit(" ч "), Self.number("45"), Self.unit(" мин")]
        )
    }

    /// A letter between two digits is a unit written against its numbers,
    /// which is how Japanese writes a duration, and never a separator.
    @Test("a unit written against the numbers on both sides of it is still a unit")
    func unitBetweenDigits() {
        #expect(
            TotalsFigureRuns.runs(of: "225時間45分")
                == [Self.number("225"), Self.unit("時間"), Self.number("45"), Self.unit("分")]
        )
        #expect(
            TotalsFigureRuns.runs(of: "1h25m")
                == [Self.number("1"), Self.unit("h"), Self.number("25"), Self.unit("m")]
        )
    }

    @Test("digits that are not 0 to 9 are the number")
    func arabicIndicDigits() {
        #expect(TotalsFigureRuns.runs(of: "٦١٤ كم") == [Self.number("٦١٤"), Self.unit(" كم")])
    }

    @Test("words after the unit stay with it")
    func trailingWords() {
        #expect(TotalsFigureRuns.runs(of: "1 113 m up") == [Self.number("1 113"), Self.unit(" m up")])
    }

    @Test("a count is all number")
    func count() {
        #expect(TotalsFigureRuns.runs(of: "1,058") == [Self.number("1,058")])
    }

    /// The dash a formatter writes for a figure that is not a number is
    /// drawn as the figure, not as a unit of nothing.
    @Test("a figure with no digit in it is drawn whole, as the number")
    func noDigits() {
        #expect(TotalsFigureRuns.runs(of: "—") == [Self.number("—")])
        #expect(TotalsFigureRuns.runs(of: "").isEmpty)
    }

    @Test(
        "what the app's formatters write is cut into pieces that put back together are the figure",
        arguments: ["en_US", "de_DE", "fr_FR", "hu_HU", "ru_RU", "hr_HR", "ja_JP", "ar_SA", "hi_IN"]
    )
    func piecesAreTheFigure(identifier: String) {
        let locale = Locale(identifier: identifier)
        let figures = [
            TotalsFormat.distance(1_058_300, locale: locale),
            TotalsFormat.distance(9300, locale: locale),
            TotalsFormat.distance(0, locale: locale),
            HikeFormat.elevation(Measurement(value: 27_224, unit: UnitLength.meters), locale: locale),
            TotalsFormat.axisDistance(150, in: TotalsFormat.chartUnit(in: locale), locale: locale),
        ]
        for figure in figures {
            let runs = TotalsFigureRuns.runs(of: figure)
            // Counted outside the macro: a key path handed to a `rethrows`
            // call inside `#expect` does not compile.
            let units = runs.count(where: \.isUnit)
            #expect(runs.map(\.text).joined() == figure)
            #expect(units > 0, "\(identifier) wrote \"\(figure)\" with no unit in it")
            #expect(units < runs.count, "\(identifier) wrote \"\(figure)\" with no number in it")
        }
    }
}
