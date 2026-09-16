//
//  WidgetFormatTests.swift
//  OpenHikesSharedTests
//
//  "Widget number formatting", split out of TrailWidgetMetricTests.swift so
//  that a file declares one @Suite. That file's header still holds the
//  context the two share.
//

import Foundation
@testable import OpenHikesShared
import Testing

@Suite("Widget number formatting")
struct WidgetFormatTests {
    private static let metric = Locale(identifier: "de_DE")
    private static let imperial = Locale(identifier: "en_US")
    /// Liberia: `ussystem`, and signs its roads in kilometres. The cheapest
    /// locale that can tell the two questions apart — a formatter that asks
    /// `measurementSystem` gives it feet and miles per hour, and a formatter
    /// that asks ICU what the roads are measured in gives it metres and
    /// kilometres per hour, which is what the region actually uses.
    private static let imperialSystemMetricRoads = Locale(identifier: "en_LR")

    /// The whole reason elevation doesn't reuse the length formatter: `.road`
    /// and `.general` both promote a four-figure height to kilometres, and a
    /// 1,250 m summit is not "1.2 km" high.
    @Test("a high summit stays in metres rather than becoming kilometres")
    func elevationIsNeverPromotedToKilometres() {
        let formatted = WidgetFormat.elevation(meters: 1250, locale: Self.metric)
        #expect(formatted.contains("1"))
        #expect(!formatted.contains("km"))
    }

    @Test("elevation follows whatever the region measures road distance in")
    func elevationFollowsTheLocale() {
        #expect(WidgetFormat.elevation(meters: 620, locale: Self.metric).contains("m"))

        let feet = WidgetFormat.elevation(meters: 620, locale: Self.imperial)
        #expect(feet.contains("ft"))
        #expect(!feet.contains(" m"))
    }

    /// The eighteen-locale case, pinned on the one that is cheapest to read.
    /// `measurementSystem` says imperial here and the roads are in
    /// kilometres, so a height in feet would contradict the distance row
    /// directly above it.
    @Test("a region with imperial units and metric roads is given metres")
    func elevationFollowsTheRoadsRatherThanTheSystem() {
        let locale = Self.imperialSystemMetricRoads
        #expect(locale.measurementSystem != .metric)

        let height = WidgetFormat.elevation(meters: 620, locale: locale)
        #expect(height.contains("m"))
        #expect(!height.contains("ft"))
    }

    /// Whole units: a chip is a few characters wide, and "2,033.5 ft" of
    /// climb is false precision on a barometer's word.
    @Test("elevation is rounded to whole units")
    func elevationIsRounded() {
        #expect(!WidgetFormat.elevation(meters: 620.4, locale: Self.metric).contains(","))
        #expect(!WidgetFormat.elevation(meters: 620.4, locale: Self.imperial).contains("."))
    }

    @Test("speed follows whatever the region measures road speed in")
    func speedFollowsTheLocale() {
        #expect(WidgetFormat.speed(metersPerSecond: 1.2, locale: Self.metric).contains("km/h"))
        #expect(WidgetFormat.speed(metersPerSecond: 1.2, locale: Self.imperial).contains("mph"))
    }

    /// The bug this pair was filed for, from the widget's side: the same fix
    /// read "5.0 km/h" in the app and "3.1 mph" here, because the app asked
    /// ICU and this asked the measurement system.
    @Test("a region with imperial units and metric roads is given km/h")
    func speedFollowsTheRoadsRatherThanTheSystem() {
        let locale = Self.imperialSystemMetricRoads
        #expect(locale.measurementSystem != .metric)

        let pace = WidgetFormat.speed(metersPerSecond: 1.2, locale: locale)
        #expect(pace.contains("km/h"))
        #expect(!pace.contains("mph"))
    }

    /// One decimal survives the usage change, which is the precision the
    /// explicit number style is there to hold.
    @Test("pace keeps one decimal", arguments: ["de_DE", "en_US", "en_LR"])
    func speedKeepsOneDecimal(identifier: String) throws {
        let locale = Locale(identifier: identifier)
        let text = WidgetFormat.speed(metersPerSecond: 1.3888888, locale: locale)
        let separator = try #require(locale.decimalSeparator)

        #expect(text.contains(separator), "expected a fraction digit in \"\(text)\"")
    }

    /// The question both formatters above are now asking, on its own. Read
    /// from the locale rather than restated, so this cannot drift into a
    /// checked-in table of regions.
    @Test("the road-unit question is asked of ICU, not of the measurement system")
    func roadUnitQuestion() {
        #expect(WidgetFormat.prefersImperialRoadUnits(in: Locale(identifier: "en_US")))
        #expect(WidgetFormat.prefersImperialRoadUnits(in: Locale(identifier: "en_GB")))
        #expect(!WidgetFormat.prefersImperialRoadUnits(in: Locale(identifier: "de_DE")))
        #expect(!WidgetFormat.prefersImperialRoadUnits(in: Locale(identifier: "ja_JP")))
        // The divergent pair, one from each measurement system.
        #expect(!WidgetFormat.prefersImperialRoadUnits(in: Locale(identifier: "en_LR")))
        #expect(!WidgetFormat.prefersImperialRoadUnits(in: Locale(identifier: "my_MM")))
    }

    /// Spelling, not substring matching: Scottish Gaelic abbreviates the mile
    /// `mì` and Lakota spells both units as words, and an implementation that
    /// looked for "mi" in the rendered string would call the first metric and
    /// the second anything at all. Both are imperial-road regions.
    @Test("a mile spelled another way is still a mile", arguments: ["gd", "lkt"])
    func roadUnitQuestionSurvivesSpelling(identifier: String) {
        #expect(WidgetFormat.prefersImperialRoadUnits(in: Locale(identifier: identifier)))
    }

    /// Memoisation must not change the answer, only the cost.
    @Test("the answer is stable across repeated asking")
    func roadUnitQuestionIsMemoised() {
        let locale = Locale(identifier: "en_LR")
        let first = WidgetFormat.prefersImperialRoadUnits(in: locale)
        for _ in 0..<3 {
            #expect(WidgetFormat.prefersImperialRoadUnits(in: locale) == first)
        }
    }

    /// The status line and the chips have to agree, which they only do while
    /// both go through here.
    @Test("the status line's distance comes from the shared length formatter")
    func statusLineUsesTheSharedFormatter() {
        let snapshot = SharedTrailSnapshot(
            hikeID: UUID(),
            title: "Ridge Loop",
            tintHex: "#34C759FF",
            totalDistanceMeters: 4200,
            polyline: []
        )
        #expect(snapshot.statusText == WidgetFormat.length(meters: 4200))
    }
}
