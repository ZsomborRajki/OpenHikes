//
//  WidgetPercentFormatTests.swift
//  OpenHikesSharedTests
//
//  The completion percentage every surface draws: the watch, the Live
//  Activity, the widget, and the app's walk and hike screens. It is held here
//  rather than in a target's suite because the watch has no test bundle, and
//  its figure is this one.
//

import Foundation
@testable import OpenHikesShared
import Testing

@Suite("Completion percentage")
struct WidgetPercentFormatTests {
    private static let english = Locale(identifier: "en_US")
    private static let german = Locale(identifier: "de_DE")

    @Test("an English percentage keeps its sign against the number")
    func englishPercentage() {
        #expect(WidgetFormat.percent(0.62, locale: Self.english) == "62%")
        #expect(WidgetFormat.percent(0, locale: Self.english) == "0%")
        #expect(WidgetFormat.percent(1, locale: Self.english) == "100%")
    }

    /// The figure the watch and the Live Activity drew as "62%" while the
    /// share card, which already asked Foundation, printed "62 %".
    @Test("a German percentage is spaced the way German writes one")
    func germanPercentage() {
        #expect(WidgetFormat.percent(0.62, locale: Self.german) == "62\u{00A0}%")
    }

    /// The locale's own percentage, digits and sign included, rather than
    /// only its spacing — what an Egyptian Arabic region reads is not "62%"
    /// with a space moved.
    @Test(
        "each locale writes the percentage its own way",
        arguments: ["en_US", "de_DE", "fr_FR", "es_ES", "ar_EG"]
    )
    func localePercentage(identifier: String) {
        let locale = Locale(identifier: identifier)
        let expected = 0.62.formatted(.percent.precision(.fractionLength(0)).locale(locale))
        #expect(WidgetFormat.percent(0.62, locale: locale) == expected)
    }

    /// Formatting the fraction itself rounds half to even, on its decimal
    /// spelling, so 0.625 would be drawn "62%" and spoken "63 percent".
    @Test("the figure drawn is the whole number spoken, halves included")
    func drawnFigureIsTheSpokenOne() {
        #expect(WidgetFormat.wholePercent(0.625) == 63)
        #expect(WidgetFormat.percent(0.625, locale: Self.english) == "63%")
        for step in 0...2000 {
            let fraction = Double(step) / 2000
            let drawn = WidgetFormat.percent(fraction, locale: Self.english)
            #expect(drawn == "\(WidgetFormat.wholePercent(fraction))%", "at \(fraction)")
        }
    }

    @Test("a fraction that is not a number reads as none rather than trapping")
    func nonFiniteFractionReadsAsNone() {
        #expect(WidgetFormat.wholePercent(.nan) == 0)
        #expect(WidgetFormat.wholePercent(.infinity) == 0)
        #expect(WidgetFormat.percent(.nan, locale: Self.english) == "0%")
    }
}
