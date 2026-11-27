//
//  WeatherPanelFiguresTests.swift
//  OpenHikesTests
//
//  The figures the weather sheet's panels draw that are worked out rather
//  than handed to a formatter: the wind as one sentence and as the compass's
//  two lines, the chance of rain a forecast says nothing about, where an
//  ultraviolet index stands on its scale, and which way "feels like" differs
//  from the temperature.
//
//  Every formatted assertion pins a `Locale`, for the reason
//  ``WeatherConditionsFormatTests`` does. The sentences are asserted by what
//  they hold, not by their spelling: the app's words are the catalog's.
//

import Foundation
@testable import OpenHikes
import RealModule
import Testing

@Suite("Weather panel figures")
struct WeatherPanelFiguresTests {
    private static let unitedStates = Locale(identifier: "en_US")
    private static let germany = Locale(identifier: "de_DE")

    private static func kilometersPerHour(_ value: Double) -> Measurement<UnitSpeed> {
        Measurement(value: value, unit: .kilometersPerHour)
    }

    private static func celsius(_ value: Double) -> Measurement<UnitTemperature> {
        Measurement(value: value, unit: .celsius)
    }

    // MARK: - Wind

    /// The card is one accessibility element, and this is what it is called:
    /// speed, the way it came from, and the gust.
    @Test("the wind is one sentence: speed, direction and gust")
    func windSentence() {
        let wind = WeatherWind(
            speed: Self.kilometersPerHour(14),
            direction: Measurement(value: 315, unit: .degrees),
            gust: Self.kilometersPerHour(22)
        )

        let spoken = WeatherReadingFormat.wind(wind)

        #expect(spoken.contains(WeatherReadingFormat.windSpeed(wind.speed)))
        #expect(spoken.contains("NW"))
        #expect(spoken.contains(WeatherReadingFormat.windSpeed(Self.kilometersPerHour(22))))
    }

    /// A still day has a wind speed and no gust, and a sentence that named
    /// one would be inventing weather.
    @Test("a wind with no gust says nothing of one")
    func windWithoutGust() {
        let calm = WeatherWind(
            speed: Self.kilometersPerHour(6),
            direction: Measurement(value: 90, unit: .degrees),
            gust: nil
        )
        let gusty = WeatherWind(speed: calm.speed, direction: calm.direction, gust: Self.kilometersPerHour(30))

        let spoken = WeatherReadingFormat.wind(calm)

        #expect(spoken.contains("E"))
        #expect(spoken.count < WeatherReadingFormat.wind(gusty).count)
        #expect(!spoken.contains(WeatherReadingFormat.windSpeed(Self.kilometersPerHour(30))))
    }

    @Test("a wind whose bearing is not a number is its speed alone")
    func windWithoutBearing() {
        let wind = WeatherWind(
            speed: Self.kilometersPerHour(14),
            direction: Measurement(value: .nan, unit: .degrees),
            gust: nil
        )

        #expect(WeatherReadingFormat.wind(wind) == WeatherReadingFormat.windSpeed(wind.speed))
        #expect(WeatherReadingFormat.windBearing(wind.direction) == nil)
    }

    /// The compass sets the figure over the unit. The two halves are the
    /// formatter's own, so together they are everything the one-line
    /// spelling says, in each region's unit.
    @Test("a wind speed comes apart into its figure and its unit")
    func windSpeedParts() {
        let wind = Self.kilometersPerHour(14)

        let german = WeatherReadingFormat.windSpeedParts(wind, locale: Self.germany)
        #expect(german.figure == "14")
        #expect(german.unit == "km/h")

        let american = WeatherReadingFormat.windSpeedParts(wind, locale: Self.unitedStates)
        #expect(american.figure == "9")
        #expect(american.unit == "mph")
    }

    @Test("a wind speed that is not a number is a dash with no unit")
    func windSpeedPartsRefuseNonsense() {
        let broken = WeatherReadingFormat.windSpeedParts(Self.kilometersPerHour(.nan), locale: Self.germany)

        #expect(broken.figure == "\u{2014}")
        #expect(broken.unit.isEmpty)
    }

    @Test("a bearing is whole degrees beside its compass point")
    func bearing() throws {
        let bearing = try #require(
            WeatherReadingFormat.windBearing(Measurement(value: 314.6, unit: .degrees), locale: Self.unitedStates)
        )

        #expect(bearing.contains("315"))
        #expect(bearing.hasSuffix("NW"))
        #expect(!bearing.contains("."))
    }

    // MARK: - The chance of rain

    /// A "0%" against every dry hour is noise where the point of the strip
    /// is to make the wet hour visible.
    @Test("a chance of rain below the floor is not drawn")
    func dryHoursSayNothing() {
        #expect(WeatherReadingFormat.precipitationChance(0, locale: Self.unitedStates) == nil)
        #expect(WeatherReadingFormat.precipitationChance(0.04, locale: Self.unitedStates) == nil)
    }

    @Test("a chance of rain at or above the floor is drawn as whole percent")
    func wetHoursSayHowLikely() {
        let floor = WeatherReadingFormat.precipitationChanceFloor

        #expect(WeatherReadingFormat.precipitationChance(floor, locale: Self.unitedStates) == "5%")
        #expect(WeatherReadingFormat.precipitationChance(0.6, locale: Self.unitedStates) == "60%")
        #expect(WeatherReadingFormat.precipitationChance(1, locale: Self.unitedStates) == "100%")
    }

    // MARK: - The ultraviolet scale

    @Test("an index stands its share of the way along the scale")
    func uvScale() {
        let top = WeatherUVIndex.scaleTop

        #expect(WeatherUVIndex(value: 0, category: .low).scaleFraction
            .isApproximatelyEqual(to: 0, absoluteTolerance: 0.001))
        #expect(WeatherUVIndex(value: top, category: .extreme).scaleFraction
            .isApproximatelyEqual(to: 1, absoluteTolerance: 0.001))
        #expect(WeatherUVIndex(value: 3, category: .moderate).scaleFraction
            .isApproximatelyEqual(to: 3.0 / Double(top), absoluteTolerance: 0.001))
    }

    /// The index has no top. A dot drawn past the end of its bar is drawn
    /// off the tile.
    @Test("an index beyond the scale is drawn at its end")
    func uvScaleHolds() {
        #expect(WeatherUVIndex(value: 14, category: .extreme).scaleFraction
            .isApproximatelyEqual(to: 1, absoluteTolerance: 0.001))
        #expect(WeatherUVIndex(value: -2, category: .low).scaleFraction
            .isApproximatelyEqual(to: 0, absoluteTolerance: 0.001))
    }

    // MARK: - Feels like

    @Test("a degree or more apart, it feels colder or warmer")
    func feelDiffers() {
        #expect(WeatherFeel(apparent: Self.celsius(10), actual: Self.celsius(12)) == .colder)
        #expect(WeatherFeel(apparent: Self.celsius(11), actual: Self.celsius(12)) == .colder)
        #expect(WeatherFeel(apparent: Self.celsius(31), actual: Self.celsius(28)) == .warmer)
        #expect(WeatherFeel(apparent: Self.celsius(29), actual: Self.celsius(28)) == .warmer)
    }

    /// Closer than a degree the two figures read the same or differ by
    /// rounding alone, and saying "colder" under an identical number would
    /// be the tile contradicting itself.
    @Test("closer than a degree, it feels similar")
    func feelIsSimilar() {
        #expect(WeatherFeel(apparent: Self.celsius(12), actual: Self.celsius(12)) == .similar)
        #expect(WeatherFeel(apparent: Self.celsius(11.4), actual: Self.celsius(12.2)) == .similar)
        #expect(WeatherFeel(apparent: Self.celsius(12.9), actual: Self.celsius(12)) == .similar)
    }

    @Test("the comparison is made in one unit, whatever each figure came in")
    func feelConvertsItsUnits() {
        // 50 °F is 10 °C.
        let apparent = Measurement(value: 50, unit: UnitTemperature.fahrenheit)

        #expect(WeatherFeel(apparent: apparent, actual: Self.celsius(12)) == .colder)
        #expect(WeatherFeel(apparent: apparent, actual: Self.celsius(10)) == .similar)
    }

    @Test("each way it can feel has words of its own")
    func everyFeelIsNamed() {
        let captions = [WeatherFeel.colder, .similar, .warmer].map(\.caption)

        #expect(Set(captions).count == 3)
        #expect(captions.allSatisfy { !$0.isEmpty })
    }
}
