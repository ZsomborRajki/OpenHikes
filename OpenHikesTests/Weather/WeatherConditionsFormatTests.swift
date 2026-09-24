//
//  WeatherConditionsFormatTests.swift
//  OpenHikesTests
//
//  The nine rows the weather sheet gained, held to the same rule the
//  temperature above them already was: the reader's region decides the unit,
//  and the provider's unit decides nothing.
//
//  Every assertion pins an explicit `Locale`, which matters more here than
//  anywhere else in this bundle. Region is the entire input these are
//  sensitive to, the CI simulator is `en_US` while the machine this is written
//  on is metric, and a suite that asked `Locale.current` would assert whatever
//  the runner happened to be set to — which is exactly how a unit bug survives
//  a green run.
//
//  Where a formatted string is Foundation's to choose rather than this app's,
//  the assertion is about the unit and the figure rather than the exact
//  spelling: what this code decides is *which* unit a region gets and how many
//  digits it is read to, and pinning a space or a symbol would be pinning a
//  framework's presentation choices as though they were ours.
//

import Foundation
@testable import OpenHikes
import Testing

@Suite("Weather conditions format")
struct WeatherConditionsFormatTests {
    private static let unitedStates = Locale(identifier: "en_US")
    private static let germany = Locale(identifier: "de_DE")
    private static let britain = Locale(identifier: "en_GB")

    // MARK: - Percentages

    /// Humidity and cloud cover arrive as fractions of one and are read as
    /// whole percent — "72.4%" in a detail row reads as a measurement rather
    /// than an observation.
    @Test("a fraction is drawn as whole percent")
    func percentages() {
        #expect(WeatherReadingFormat.percentage(0.72, locale: Self.unitedStates) == "72%")
        #expect(WeatherReadingFormat.percentage(0, locale: Self.unitedStates) == "0%")
        #expect(WeatherReadingFormat.percentage(1, locale: Self.unitedStates) == "100%")
        // Rounded rather than truncated, so 72.4 and 72.6 do not both read 72.
        #expect(WeatherReadingFormat.percentage(0.726, locale: Self.unitedStates) == "73%")
    }

    // MARK: - Wind

    /// The same wind, in the unit each region measures speed in.
    ///
    /// 14 km/h is 8.7 mph, so the two regions disagree about the number as
    /// well as the unit — which is the point. A formatter pinned to the
    /// provider's unit would have shown every reader the same "14".
    @Test("a wind speed is converted to the region's own unit")
    func windSpeedFollowsTheRegion() {
        let wind = Measurement(value: 14, unit: UnitSpeed.kilometersPerHour)

        let american = WeatherReadingFormat.windSpeed(wind, locale: Self.unitedStates)
        #expect(american.contains("mph"))
        #expect(american.contains("9"))

        let german = WeatherReadingFormat.windSpeed(wind, locale: Self.germany)
        #expect(german.contains("km/h"))
        #expect(german.contains("14"))
    }

    /// Whole units, unlike the hiker's own pace.
    ///
    /// A tenth of a kilometre per hour separates one stroll from another and
    /// says nothing at all about wind, so the decimal that `HikeFormat.speed`
    /// keeps is deliberately not kept here.
    @Test("a wind speed carries no decimal")
    func windSpeedIsWhole() {
        let gusty = Measurement(value: 23.6, unit: UnitSpeed.kilometersPerHour)

        let german = WeatherReadingFormat.windSpeed(gusty, locale: Self.germany)

        #expect(german.contains("24"))
        #expect(!german.contains(","))
        #expect(!german.contains("."))
    }

    @Test("a wind speed that is not a number is a dash, not a figure")
    func windSpeedRefusesNonsense() {
        let broken = Measurement(value: .nan, unit: UnitSpeed.kilometersPerHour)

        #expect(WeatherReadingFormat.windSpeed(broken, locale: Self.germany) == "\u{2014}")
    }

    /// Sixteen points, north first, clockwise.
    ///
    /// The boundaries are where an off-by-one shows: each point owns 22.5°
    /// centred on its own bearing, so 11.25° is the first edge and anything
    /// below it is still north.
    @Test(
        "a bearing becomes the compass point it falls in",
        arguments: [
            (0.0, "N"),
            (11.0, "N"),
            (22.5, "NNE"),
            (45.0, "NE"),
            (90.0, "E"),
            (180.0, "S"),
            (270.0, "W"),
            (315.0, "NW"),
            (337.5, "NNW"),
        ]
    )
    func compassPoints(degrees: Double, expected: String) {
        let direction = Measurement(value: degrees, unit: UnitAngle.degrees)

        #expect(WeatherReadingFormat.windDirection(direction) == expected)
    }

    /// The wrap, which is the half a modulo gets wrong in one direction.
    ///
    /// 350° rounds to the seventeenth sector and has to come back to north
    /// rather than run off the end of the array; a negative bearing has to
    /// come back to the same place rather than index backwards.
    @Test("a bearing past north wraps to north, from either side")
    func compassWraps() {
        #expect(
            WeatherReadingFormat.windDirection(
                Measurement(value: 350, unit: UnitAngle.degrees)
            ) == "N"
        )
        #expect(
            WeatherReadingFormat.windDirection(
                Measurement(value: 360, unit: UnitAngle.degrees)
            ) == "N"
        )
        #expect(
            WeatherReadingFormat.windDirection(
                Measurement(value: -45, unit: UnitAngle.degrees)
            ) == "NW"
        )
    }

    /// Radians in, compass point out: the bearing is converted rather than
    /// read off `.value`, so a provider that changes its mind about the unit
    /// cannot turn north into east.
    @Test("a bearing in another unit is converted, not read raw")
    func compassConvertsItsUnit() {
        let east = Measurement(value: Double.pi / 2, unit: UnitAngle.radians)

        #expect(WeatherReadingFormat.windDirection(east) == "E")
    }

    @Test("a bearing that is not a number has no direction")
    func compassRefusesNonsense() {
        let broken = Measurement(value: .nan, unit: UnitAngle.degrees)

        #expect(WeatherReadingFormat.windDirection(broken) == nil)
    }

    // MARK: - Pressure, visibility, precipitation

    /// Inches of mercury where they are read, hectopascals where they are not.
    @Test("pressure is barometric, in the region's own unit")
    func pressureFollowsTheRegion() {
        let pressure = Measurement(value: 1013, unit: UnitPressure.hectopascals)

        #expect(WeatherReadingFormat.pressure(pressure, locale: Self.unitedStates).contains("inHg"))
        let german = WeatherReadingFormat.pressure(pressure, locale: Self.germany)
        #expect(german.contains("hPa"))
        #expect(german.contains("013"))
    }

    /// The digits are given a range rather than a count, because the two units
    /// are read to different precision: 29.92 inHg is the interesting figure
    /// and 30 inHg is not, while 1013.25 hPa is noise.
    @Test("pressure keeps the digits its unit is read to")
    func pressureKeepsUsefulDigits() {
        let pressure = Measurement(value: 1013.25, unit: UnitPressure.hectopascals)

        let american = WeatherReadingFormat.pressure(pressure, locale: Self.unitedStates)

        #expect(american.contains("29."))
    }

    /// Visibility is a distance a person judges the way they judge a road, so
    /// it takes the same unit the hike's own distance row does — which is what
    /// stops the two disagreeing in the same app.
    @Test("visibility takes the region's road unit")
    func visibilityFollowsTheRegion() {
        let visibility = Measurement(value: 10, unit: UnitLength.kilometers)

        #expect(WeatherReadingFormat.visibility(visibility, locale: Self.britain).contains("mi"))
        #expect(WeatherReadingFormat.visibility(visibility, locale: Self.germany).contains("km"))
    }

    /// A depth per hour, which is what the provider means by a "speed" of
    /// millimetres per hour — see ``WeatherConditions/precipitationIntensity``.
    @Test("precipitation is a depth with an hour on it")
    func precipitationIsADepthPerHour() {
        let rain = Measurement(value: 2.5, unit: UnitLength.millimeters)

        let german = WeatherReadingFormat.precipitation(rain, locale: Self.germany)
        #expect(german.contains("mm"))
        #expect(german.hasSuffix("/h"))

        // And the region still chooses: a reader in `en_US` gets inches.
        let american = WeatherReadingFormat.precipitation(rain, locale: Self.unitedStates)
        #expect(american.contains("in"))
        #expect(american.hasSuffix("/h"))
    }

    // MARK: - Ultraviolet

    /// The number and the band, because neither is enough alone: "8" means
    /// nothing to somebody who does not know the scale, and "Very High" throws
    /// away the part that can be compared against yesterday.
    @Test("the UV index carries its number and its band")
    func uvIndexCarriesBoth() {
        let moderate = WeatherUVIndex(value: 3, category: .moderate)

        let formatted = WeatherReadingFormat.uvIndex(moderate)

        #expect(formatted.contains("3"))
        #expect(formatted.contains("Moderate"))
    }

    @Test("every band has words of its own")
    func everyBandIsNamed() {
        let labels = WeatherUVCategory.allCases.map(\.label)

        #expect(Set(labels).count == WeatherUVCategory.allCases.count)
        #expect(labels.allSatisfy { !$0.isEmpty })
    }
}
