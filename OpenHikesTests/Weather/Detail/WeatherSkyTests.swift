//
//  WeatherSkyTests.swift
//  OpenHikesTests
//
//  The weather sheet's backdrop is read off the symbol WeatherKit names for
//  the conditions, and everything on it is drawn in white. Two things can go
//  wrong with that, and neither shows in a run that happens to be sunny: a
//  symbol read as the wrong sky, and a sky too pale to read white text on.
//
//  The contrasts are measured on the colors as they are drawn: a panel is its
//  fill laid over the sky, and the quieter text is white thinned over that,
//  each mixed in sRGB as SwiftUI composites them. A text color held only as
//  an opaque white would pass while the text drawn in it did not.
//
//  The symbol names here are WeatherKit's own, as it hands them over for a
//  condition by day and by night.
//

import Foundation
@testable import OpenHikes
import Testing

@Suite("Weather sky")
struct WeatherSkyTests {
    private static let noon = Date(timeIntervalSinceReferenceDate: 800_000_000)

    /// A day whose sun is up at ``noon``: six hours either side of it.
    private static let daylight = WeatherDaylight(
        sunrise: noon.addingTimeInterval(-6 * 3600),
        sunset: noon.addingTimeInterval(6 * 3600),
        civilDusk: noon.addingTimeInterval(6.5 * 3600)
    )

    private static func sky(
        _ symbolName: String,
        daylight: WeatherDaylight? = daylight,
        asOf date: Date = noon
    ) -> WeatherSky {
        WeatherSky(symbolName: symbolName, daylight: daylight, asOf: date)
    }

    @Test("a symbol is read as the sky its words describe", arguments: [
        ("sun.max.fill", WeatherSky.Cover.clear),
        ("moon.stars.fill", .clear),
        ("cloud.sun.fill", .partlyCloudy),
        ("cloud.moon.fill", .partlyCloudy),
        ("cloud.fill", .overcast),
        ("wind", .overcast),
        ("cloud.drizzle.fill", .rain),
        ("cloud.heavyrain.fill", .rain),
        ("cloud.sun.rain.fill", .rain),
        ("cloud.snow.fill", .snow),
        ("cloud.sleet.fill", .snow),
        ("cloud.hail.fill", .snow),
        ("snowflake", .snow),
        ("cloud.fog.fill", .fog),
        ("sun.haze.fill", .fog),
        ("smoke.fill", .fog),
        ("cloud.bolt.fill", .storm),
        ("hurricane", .storm),
    ])
    func cover(symbolName: String, expected: WeatherSky.Cover) {
        #expect(Self.sky(symbolName).cover == expected)
    }

    /// A thunderstorm's symbol names its rain and its cloud as well, and a
    /// snow shower under a sun names the sun: the backdrop is the worst of
    /// what the symbol says.
    @Test("the worst word in a symbol decides")
    func worstWins() {
        #expect(Self.sky("cloud.bolt.rain.fill").cover == .storm)
        #expect(Self.sky("cloud.sun.bolt.fill").cover == .storm)
        #expect(Self.sky("wind.snow").cover == .snow)
        #expect(Self.sky("sun.snow.fill").cover == .snow)
    }

    @Test("a variant the sheet has never seen lands on the same sky")
    func unknownVariants() {
        #expect(Self.sky("cloud.rain") == Self.sky("cloud.rain.fill"))
        #expect(Self.sky("cloud.sun.circle.fill").cover == .partlyCloudy)
        // None of the words: a color, not a claim.
        #expect(Self.sky("questionmark").cover == .clear)
        #expect(Self.sky("").cover == .clear)
    }

    /// WeatherKit names the sun or the moon wherever either can be seen, and
    /// the reading's own daylight can be a day old by the time it is drawn.
    @Test("the sun or the moon in a symbol outranks the clock")
    func symbolDecidesDayOrNight() {
        let midnight = Self.noon.addingTimeInterval(12 * 3600)

        #expect(Self.sky("moon.stars.fill", asOf: Self.noon).isDaylight == false)
        #expect(Self.sky("cloud.moon.rain.fill", asOf: Self.noon).isDaylight == false)
        #expect(Self.sky("sun.max.fill", asOf: midnight).isDaylight)
        #expect(Self.sky("cloud.sun.fill", asOf: midnight).isDaylight)
    }

    @Test("under cloud, sunrise and sunset decide")
    func daylightDecidesUnderCloud() {
        let beforeSunrise = Self.noon.addingTimeInterval(-7 * 3600)
        let afterSunset = Self.noon.addingTimeInterval(7 * 3600)
        let sunset = Self.noon.addingTimeInterval(6 * 3600)

        #expect(Self.sky("cloud.fill", asOf: Self.noon).isDaylight)
        #expect(Self.sky("cloud.rain.fill", asOf: beforeSunrise).isDaylight == false)
        #expect(Self.sky("cloud.fill", asOf: afterSunset).isDaylight == false)
        // The sun is down from the moment it sets, not a second after.
        #expect(Self.sky("cloud.fill", asOf: sunset).isDaylight == false)
    }

    /// A polar summer has no sunset, and a reading restored from an old blob
    /// has no daylight at all. Neither is a reason to draw a night.
    @Test("with no sunrise or sunset to ask, it is day")
    func missingDaylightIsDay() {
        let polar = WeatherDaylight(sunrise: nil, sunset: nil, civilDusk: nil)

        #expect(Self.sky("cloud.fill", daylight: nil).isDaylight)
        #expect(Self.sky("cloud.fill", daylight: polar).isDaylight)
        #expect(Self.sky("snowflake", daylight: WeatherDaylight(sunrise: Self.noon)).isDaylight)
    }

    @Test("a reading's sky is its symbol's")
    func readsASnapshot() {
        let reading = WeatherSnapshot(
            symbolName: "cloud.moon.fill",
            temperature: Measurement(value: 12, unit: UnitTemperature.celsius),
            conditionDescription: "Partly Cloudy",
            capturedAt: Self.noon,
            conditions: .preview
        )

        #expect(WeatherSky(reading, asOf: Self.noon) == WeatherSky(cover: .partlyCloudy, isDaylight: false))
    }

    // MARK: - Its colors

    private static var everySky: [WeatherSky] {
        WeatherSky.Cover.allCases.flatMap { cover in
            [WeatherSky(cover: cover, isDaylight: true), WeatherSky(cover: cover, isDaylight: false)]
        }
    }

    private static let white = WeatherTint(red: 1, green: 1, blue: 1)
    /// What WCAG asks of small text: everything on the sheet below a
    /// heading's size, the footnotes and the figures down the days among it.
    private static let smallTextContrast = 4.5

    /// A color's relative luminance, as WCAG measures it.
    private static func luminance(_ tint: WeatherTint) -> Double {
        let linear = [tint.red, tint.green, tint.blue].map { channel in
            channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
    }

    /// One color against another, as WCAG measures it.
    private static func contrast(_ one: WeatherTint, _ other: WeatherTint) -> Double {
        let lighter = max(luminance(one), luminance(other))
        let darker = min(luminance(one), luminance(other))
        return (lighter + 0.05) / (darker + 0.05)
    }

    private static func contrastWithWhite(_ tint: WeatherTint) -> Double {
        contrast(white, tint)
    }

    /// The head of the sheet is set straight on the backdrop, and so are the
    /// credits, the footnotes and the eyebrow over the place's name, all of
    /// it in white and some of it small. Anything can scroll down to the
    /// horizon, so every color of every sky has to carry small text. A sky
    /// lightened to look more like the snow or the fog it stands for fails
    /// here first.
    @Test("every sky is dark enough for the small white text set on it")
    func everySkyCarriesWhiteText() throws {
        for sky in Self.everySky {
            for hex in [sky.backdrop.zenith, sky.backdrop.horizon] {
                let tint = try #require(WeatherTint(hex: hex), "\(hex) is not a color")
                #expect(Self.contrastWithWhite(tint) >= Self.smallTextContrast, "\(sky) at \(hex)")
            }
        }
    }

    @Test("every sky is deeper overhead than at the horizon")
    func zenithIsDeeper() throws {
        for sky in Self.everySky {
            let zenith = try #require(WeatherTint(hex: sky.backdrop.zenith))
            let horizon = try #require(WeatherTint(hex: sky.backdrop.horizon))
            #expect(Self.contrastWithWhite(zenith) > Self.contrastWithWhite(horizon), "\(sky)")
        }
    }

    // MARK: - Its panels

    /// A sky's panel as it is seen: its fill laid over a color of the sky.
    private static func panel(of sky: WeatherSky, over hex: String) throws -> WeatherTint {
        let under = try #require(WeatherTint(hex: hex))
        let fill = try #require(WeatherTint(hex: sky.panel.tint))
        return under.mixed(with: fill, by: sky.panel.opacity)
    }

    /// The panels hold the sheet's small type: the rows, the captions, the
    /// figures down the days. The panel is drawn over every color the sky
    /// has, the palest included.
    @Test("every sky's panel carries small white text, wherever on the sky it is")
    func everyPanelCarriesWhiteText() throws {
        for sky in Self.everySky {
            for hex in [sky.backdrop.zenith, sky.backdrop.horizon] {
                let panel = try Self.panel(of: sky, over: hex)
                #expect(Self.contrastWithWhite(panel) >= Self.smallTextContrast, "\(sky) over \(hex)")
            }
        }
    }

    /// Most of a panel's small type is not white but white thinned: the
    /// headings, the lows down the days, the values beside their labels, the
    /// compass's letters. Measured as drawn, thinned over the panel over the
    /// sky, because that is the color the eye gets.
    @Test("every sky's panel carries its quieter text, wherever on the sky it is")
    func everyPanelCarriesQuietText() throws {
        for sky in Self.everySky {
            for hex in [sky.backdrop.zenith, sky.backdrop.horizon] {
                let panel = try Self.panel(of: sky, over: hex)
                let text = panel.mixed(with: Self.white, by: WeatherSky.quietTextOpacity)
                #expect(Self.contrast(text, panel) >= Self.smallTextContrast, "\(sky) over \(hex)")
            }
        }
    }

    /// The chance of rain is the smallest figure on the sheet, in a color of
    /// its own, under each hour and each day.
    @Test("every sky's panel carries the chance of rain, wherever on the sky it is")
    func everyPanelCarriesTheChanceOfRain() throws {
        let cyan = try #require(WeatherTint(hex: WeatherSky.rainChanceTint))
        for sky in Self.everySky {
            for hex in [sky.backdrop.zenith, sky.backdrop.horizon] {
                let panel = try Self.panel(of: sky, over: hex)
                #expect(Self.contrast(cyan, panel) >= Self.smallTextContrast, "\(sky) over \(hex)")
            }
        }
    }

    /// A panel nobody can tell from the sky is a heading floating over
    /// nothing. By day the panel is the darker of the two and by night the
    /// lighter, and either way the difference has to be one the eye finds.
    @Test("every sky's panel stands apart from the sky behind it")
    func everyPanelStandsApart() throws {
        for sky in Self.everySky {
            for hex in [sky.backdrop.zenith, sky.backdrop.horizon] {
                let under = try #require(WeatherTint(hex: hex))
                let panel = try Self.panel(of: sky, over: hex)
                let ratio = Self.contrastWithWhite(panel) / Self.contrastWithWhite(under)
                #expect(sky.isDaylight ? ratio >= 1.15 : ratio <= 1 / 1.15, "\(sky) over \(hex)")
            }
        }
    }

    @Test("a night is darker than the same sky by day")
    func nightIsDarker() throws {
        for cover in WeatherSky.Cover.allCases {
            let day = try #require(WeatherTint(hex: WeatherSky(cover: cover, isDaylight: true).backdrop.zenith))
            let night = try #require(WeatherTint(hex: WeatherSky(cover: cover, isDaylight: false).backdrop.zenith))
            #expect(Self.contrastWithWhite(night) > Self.contrastWithWhite(day), "\(cover)")
        }
    }
}
