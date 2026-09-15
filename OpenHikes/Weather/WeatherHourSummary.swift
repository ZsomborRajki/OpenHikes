//
//  WeatherHourSummary.swift
//  OpenHikes
//
//  One hour of the forecast, as the app holds it.
//
//  ## Why this exists
//
//  The current temperature is the least useful weather fact to somebody
//  standing at a trailhead. What decides whether a walk happens is the next
//  few hours: whether the rain arrives before the ridge, and what the sky is
//  doing on the exposed section. ``WeatherSubject`` already models the three
//  things the badge can be about — a recording, a selected trail, a searched
//  city — and all three are forward-looking questions.
//
//  ## It is not a second request
//
//  `WeatherService.weather(for:including:)` takes a variadic set of datasets
//  and answers them from one call, so `.current, .hourly` costs the round trip
//  the badge was already spending, against the same ``WeatherRequestState``
//  floors and the same fifteen-minute freshness window. That is the whole
//  reason this is cheap, and the reason to keep it in the same fetch if it
//  ever moves.
//
//  ## Why it is a value with no WeatherKit in it
//
//  The same argument ``WeatherSnapshot`` and ``WeatherConditions`` give.
//  `HourWeather` has no public initializer, so folding it in would put the
//  strip beyond the reach of a preview, a suite or a UI-automation launch —
//  and the mapping therefore lives in the one file that already speaks
//  WeatherKit rather than here.
//

import Foundation

/// What one hour of the forecast says, in the units the provider used.
///
/// Converted on the way to the screen rather than on the way in, which is the
/// rule ``WeatherReadingFormat`` already keeps for the current temperature.
nonisolated struct WeatherHourSummary: Equatable, Sendable, Identifiable {
    /// The hour this describes, at its start.
    let date: Date
    let symbolName: String
    let temperature: Measurement<UnitTemperature>
    /// The chance of precipitation in this hour, 0...1.
    ///
    /// Carried even when it is zero, because a strip that draws the figure
    /// only for some hours makes a dry hour and an unreported one look the
    /// same. The *drawing* decision belongs to the sheet.
    let precipitationChance: Double

    /// Identity is the hour itself. Two summaries for the same hour are the
    /// same row, which is what a re-fetch during the same hour produces.
    var id: Date { date }
}

/// How much of the forecast is worth keeping.
nonisolated enum WeatherHourlyPolicy {
    /// Twelve hours.
    ///
    /// The argument for the strip is about the next six — the rain before the
    /// ridge, the UV peak, the wind on the exposed section — and twelve is
    /// that with enough either side to be worth scrolling. It also bounds the
    /// stored blob: `.hourly` answers with days of data, and all of it would
    /// otherwise be written to `UserDefaults` on every successful fetch.
    static let horizon = 12

    /// One hour, in seconds. Here rather than as a `TimeInterval` extension
    /// because `SWIFT_DEFAULT_ACTOR_ISOLATION` is `MainActor` in this module,
    /// and the mapping that needs it is `nonisolated` for the reason
    /// ``WeatherSnapshot`` gives.
    static let hourSeconds: TimeInterval = 3600
}

#if DEBUG
extension WeatherHourSummary {
    /// A filled strip, for previews and the `--ui-test-weather` fixture.
    ///
    /// Computed rather than stored, for the reason
    /// ``WeatherSnapshot/uiTestFixture`` gives: a `static let` is initialized
    /// once, and these hours are relative to *now*. One stored at launch would
    /// hand a long simulator session a strip describing yesterday afternoon.
    ///
    /// Every hour differs from its neighbours in a way that is visible on
    /// screen — the temperature climbs and falls, and exactly one hour is wet
    /// — so a column wired to the wrong value shows it rather than rendering a
    /// plausible number.
    static var previewStrip: [Self] {
        let start = Date.now
        return (0..<Preview.hours).map { offset in
            Self(
                date: start.addingTimeInterval(Double(offset) * WeatherHourlyPolicy.hourSeconds),
                symbolName: offset == Preview.wetHour ? "cloud.rain.fill" : "cloud.sun.fill",
                temperature: Measurement(
                    value: Preview.celsius(atHour: offset),
                    unit: UnitTemperature.celsius
                ),
                precipitationChance: offset == Preview.wetHour ? Preview.wetChance : 0
            )
        }
    }

    /// The fixture's numbers, named so the linter can tell a strip from a row
    /// of arithmetic constants.
    private enum Preview {
        static let hours = 12
        /// Far enough in that it is not the first column, which is the one a
        /// mis-indexed strip would put it in.
        static let wetHour = 4
        static let wetChance = 0.6
        static let peakCelsius: Double = 16
        static let swingCelsius: Double = 4

        /// A day that warms to ``peakCelsius`` and cools again, so no two
        /// adjacent columns read the same.
        static func celsius(atHour offset: Int) -> Double {
            peakCelsius - abs(Double(offset - wetHour)) * swingCelsius / Double(wetHour)
        }
    }
}
#endif
