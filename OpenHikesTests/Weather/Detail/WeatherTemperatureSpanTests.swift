//
//  WeatherTemperatureSpanTests.swift
//  OpenHikesTests
//
//  The daily forecast draws each day's low and high as a bar on one scale,
//  the week's, and colors it by what the temperature is. The bars are only
//  worth reading if the scale is the same for every row, holds whatever it
//  is handed, and gives one temperature one color in every week.
//

import Foundation
@testable import OpenHikes
import RealModule
import Testing

@Suite("Weather temperature span")
struct WeatherTemperatureSpanTests {
    private static let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private static func celsius(_ value: Double) -> Measurement<UnitTemperature> {
        Measurement(value: value, unit: .celsius)
    }

    private static func week(_ ranges: [(low: Double, high: Double)]) -> [WeatherDaySummary] {
        ranges.enumerated().map { offset, range in
            WeatherDaySummary(
                date: start.addingTimeInterval(Double(offset) * 86_400),
                symbolName: "cloud.sun.fill",
                highTemperature: celsius(range.high),
                lowTemperature: celsius(range.low),
                precipitationChance: 0
            )
        }
    }

    // MARK: - The scale

    @Test("the scale runs from the week's coldest low to its warmest high")
    func spansTheWeek() throws {
        let span = try #require(WeatherTemperatureSpan(days: Self.week([(4, 12), (-2, 6), (8, 18)])))

        #expect(span.lower.isApproximatelyEqual(to: -2, absoluteTolerance: 0.001))
        #expect(span.upper.isApproximatelyEqual(to: 18, absoluteTolerance: 0.001))
    }

    @Test("a week with no day in it has no scale")
    func emptyWeek() {
        #expect(WeatherTemperatureSpan(days: []) == nil)
    }

    /// A forecast in Fahrenheit is the same week: 32 °F to 68 °F is 0 to 20.
    @Test("the scale is in Celsius whatever unit the forecast came in")
    func convertsItsUnit() throws {
        let day = WeatherDaySummary(
            date: Self.start,
            symbolName: "sun.max.fill",
            highTemperature: Measurement(value: 68, unit: .fahrenheit),
            lowTemperature: Measurement(value: 32, unit: .fahrenheit),
            precipitationChance: 0
        )
        let span = try #require(WeatherTemperatureSpan(days: [day]))

        #expect(span.lower.isApproximatelyEqual(to: 0, absoluteTolerance: 0.001))
        #expect(span.upper.isApproximatelyEqual(to: 20, absoluteTolerance: 0.001))
        #expect(span.fraction(of: Measurement(value: 50, unit: .fahrenheit))
            .isApproximatelyEqual(to: 0.5, absoluteTolerance: 0.001))
    }

    /// Seven days of one temperature would divide by nothing. They are drawn
    /// on a scale a degree wide, the temperature in its middle.
    @Test("a week of one temperature still has a scale")
    func flatWeek() throws {
        let span = try #require(WeatherTemperatureSpan(days: Self.week([(10, 10), (10, 10)])))

        #expect((span.upper - span.lower).isApproximatelyEqual(
            to: WeatherTemperatureSpan.narrowest,
            absoluteTolerance: 0.001
        ))
        #expect(span.fraction(of: Self.celsius(10)).isApproximatelyEqual(to: 0.5, absoluteTolerance: 0.001))
    }

    @Test("a temperature that is not a number is left out of the scale")
    func ignoresNonsense() throws {
        var days = Self.week([(2, 9)])
        days += [
            WeatherDaySummary(
                date: Self.start.addingTimeInterval(86_400),
                symbolName: "cloud.fill",
                highTemperature: Self.celsius(.nan),
                lowTemperature: Self.celsius(.infinity),
                precipitationChance: 0
            ),
        ]
        let span = try #require(WeatherTemperatureSpan(days: days))

        #expect(span.lower.isApproximatelyEqual(to: 2, absoluteTolerance: 0.001))
        #expect(span.upper.isApproximatelyEqual(to: 9, absoluteTolerance: 0.001))
        #expect(span.fraction(of: Self.celsius(.nan)).isApproximatelyEqual(to: 0, absoluteTolerance: 0.001))
    }

    // MARK: - A day on it

    @Test("a temperature's place is its share of the way along")
    func fractions() {
        let span = WeatherTemperatureSpan(lower: 0, upper: 20)

        #expect(span.fraction(of: Self.celsius(0)).isApproximatelyEqual(to: 0, absoluteTolerance: 0.001))
        #expect(span.fraction(of: Self.celsius(5)).isApproximatelyEqual(to: 0.25, absoluteTolerance: 0.001))
        #expect(span.fraction(of: Self.celsius(20)).isApproximatelyEqual(to: 1, absoluteTolerance: 0.001))
    }

    /// The reading can be a degree outside the forecast's range for the day,
    /// and a dot drawn off the end of the scale is drawn off the card.
    @Test("a temperature beyond the scale is held at its end")
    func clamps() {
        let span = WeatherTemperatureSpan(lower: 0, upper: 20)

        #expect(span.fraction(of: Self.celsius(-8)).isApproximatelyEqual(to: 0, absoluteTolerance: 0.001))
        #expect(span.fraction(of: Self.celsius(31)).isApproximatelyEqual(to: 1, absoluteTolerance: 0.001))
    }

    @Test("a day covers the stretch from its low to its high")
    func extent() {
        let span = WeatherTemperatureSpan(lower: 0, upper: 20)

        let day = span.extent(from: Self.celsius(5), to: Self.celsius(15))
        #expect(day.lowerBound.isApproximatelyEqual(to: 0.25, absoluteTolerance: 0.001))
        #expect(day.upperBound.isApproximatelyEqual(to: 0.75, absoluteTolerance: 0.001))

        // A forecast with its ends the wrong way round is still a stretch,
        // not a trap: `ClosedRange` refuses a lower bound above its upper.
        let reversed = span.extent(from: Self.celsius(15), to: Self.celsius(5))
        #expect(reversed == day)
    }

    // MARK: - Its colors

    @Test("the colors are parsed, every one")
    func everyAnchorIsAColor() {
        #expect(WeatherTemperatureColor.anchors.count == 11)
    }

    @Test("a hex color is read by its parts")
    func hex() throws {
        let tint = try #require(WeatherTint(hex: "#FF8000"))

        #expect(tint.red.isApproximatelyEqual(to: 1, absoluteTolerance: 0.001))
        #expect(tint.green.isApproximatelyEqual(to: 128.0 / 255, absoluteTolerance: 0.001))
        #expect(tint.blue.isApproximatelyEqual(to: 0, absoluteTolerance: 0.001))
        #expect(WeatherTint(hex: "FF8000") == tint)
        #expect(WeatherTint(hex: "#FF80") == nil)
        #expect(WeatherTint(hex: "#GG8000") == nil)
    }

    @Test("a temperature on a color's own mark is that color, and between two is between them")
    func tints() {
        let anchors = WeatherTemperatureColor.anchors
        let coldest = WeatherTemperatureColor.coldest
        let step = WeatherTemperatureColor.step

        #expect(WeatherTemperatureColor.tint(atCelsius: coldest) == anchors[0])
        #expect(WeatherTemperatureColor.tint(atCelsius: coldest + step * 3) == anchors[3])
        #expect(
            WeatherTemperatureColor.tint(atCelsius: coldest + step * 3.5)
                == anchors[3].mixed(with: anchors[4], by: 0.5)
        )
    }

    @Test("beyond the coldest and the warmest color, the last one holds")
    func tintsHoldAtTheEnds() {
        let anchors = WeatherTemperatureColor.anchors

        #expect(WeatherTemperatureColor.tint(atCelsius: -60) == anchors.first)
        #expect(WeatherTemperatureColor.tint(atCelsius: 60) == anchors.last)
        #expect(WeatherTemperatureColor.tint(atCelsius: .nan) == anchors.first)
    }

    /// One gradient is laid across the whole scale and each day's bar is a
    /// window onto it. So its stops have to start at one end, finish at the
    /// other and never step backwards, and each has to be the color of the
    /// temperature that stands there.
    @Test("a week's gradient runs end to end, in order, in the colors of its temperatures")
    func stops() {
        let span = WeatherTemperatureSpan(lower: 0, upper: 20)
        let stops = WeatherTemperatureColor.stops(across: span)

        #expect(stops.first?.location.isApproximatelyEqual(to: 0, absoluteTolerance: 0.001) == true)
        #expect(stops.last?.location.isApproximatelyEqual(to: 1, absoluteTolerance: 0.001) == true)
        #expect(stops.map(\.location) == stops.map(\.location).sorted())
        // The ends, and the colors standing at 4°, 10° and 16° between them.
        #expect(stops.count == 5)
        for stop in stops {
            let celsius = span.lower + stop.location * (span.upper - span.lower)
            let expected = WeatherTemperatureColor.tint(atCelsius: celsius)
            #expect(stop.tint.red.isApproximatelyEqual(to: expected.red, absoluteTolerance: 0.001))
            #expect(stop.tint.green.isApproximatelyEqual(to: expected.green, absoluteTolerance: 0.001))
            #expect(stop.tint.blue.isApproximatelyEqual(to: expected.blue, absoluteTolerance: 0.001))
        }
    }

    /// 4° is the same color in a week of frost and in a week of heat, which
    /// is what lets the color be read without the figures.
    @Test("one temperature is one color in every week")
    func colorIsAbsolute() {
        let frost = WeatherTemperatureSpan(lower: -12, upper: 4)
        let thaw = WeatherTemperatureSpan(lower: 4, upper: 19)

        #expect(WeatherTemperatureColor.stops(across: frost).last?.tint
            == WeatherTemperatureColor.stops(across: thaw).first?.tint)
    }
}
