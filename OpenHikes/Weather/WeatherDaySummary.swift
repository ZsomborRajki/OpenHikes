//
//  WeatherDaySummary.swift
//  OpenHikes
//
//  One day of the forecast, as the app holds it.
//
//  ## Why this exists
//
//  `.daily` has been in the request since ``WeatherDaylight``, and until now
//  the app read the first day of it and dropped the other nine. That was not
//  waste for its own sake — the daylight section needs today's sunset and
//  nothing else — but it left the question a hiker actually brings to a
//  hiking app unanswered: *which day this week should I go*. Twelve hours of
//  ``WeatherHourSummary`` is the right answer once a walk has started and the
//  wrong one the evening before, and the data to answer it properly was
//  already being decoded and thrown away.
//
//  ## It is not a second request, and not even a second dataset
//
//  Unlike the hourly strip, which at least added `.hourly` to the variadic
//  set, this costs nothing at all on the network: the same
//  `weather(for:including:)` call already asks for `.daily` and already
//  receives ten days of it. What this adds is the mapping and the rows.
//
//  ## Why it is a value with no WeatherKit in it
//
//  The argument ``WeatherHourSummary`` gives, unchanged: `DayWeather` has no
//  public initializer, so folding it in would put the day strip beyond the
//  reach of a preview, a suite or a UI-automation launch — and the mapping
//  therefore lives in the one file that already speaks WeatherKit rather than
//  here.
//
//  ## What a day row deliberately does not carry
//
//  Sunrise and sunset, which are the obvious things to want here and are the
//  reason to say so. Above the Arctic Circle a day has neither — see
//  ``WeatherDaylight``, whose header explains why that is a fact to draw
//  rather than a failure to handle — so a per-day daylight figure would have
//  to be optional per day, and a strip of seven rows where some have a sunset
//  and some do not reads as missing data rather than as the midnight sun.
//  Today's light already has a section of its own that makes the distinction
//  properly. Anything added here later inherits that requirement.
//

import Foundation

/// What one day of the forecast says, in the units the provider used.
///
/// Converted on the way to the screen rather than on the way in, which is the
/// rule ``WeatherReadingFormat`` keeps for every other temperature in this
/// feature.
nonisolated struct WeatherDaySummary: Equatable, Sendable, Identifiable {
    /// The day this describes, at its start, as the provider dated it.
    let date: Date
    let symbolName: String
    let highTemperature: Measurement<UnitTemperature>
    let lowTemperature: Measurement<UnitTemperature>
    /// The chance of precipitation across the day, 0...1.
    ///
    /// Carried even when it is zero, for the reason
    /// ``WeatherHourSummary/precipitationChance`` is: a strip that draws the
    /// figure only for some days makes a dry day and an unreported one look
    /// the same, and the *drawing* decision belongs to the sheet.
    let precipitationChance: Double

    /// Identity is the day itself. Two summaries for the same day are the same
    /// row, which is what a re-fetch during the same day produces.
    var id: Date { date }
}

extension WeatherDaySummary {
    /// The days of `week` that have not ended yet, as of `date`.
    ///
    /// **Applied on the way to the screen as well as on the way in**, and
    /// that is not belt-and-braces. Nothing in ``WeatherManager`` expires: a
    /// reading restored from the stored blob, or one carried in the in-memory
    /// cache while the app sat in a rucksack overnight, is drawn exactly as it
    /// was fetched. Filtered only at the fetch, such a reading opens the strip
    /// on yesterday — a first row named for the weekday it was, with no row
    /// saying *Today* anywhere beneath it.
    ///
    /// **A day is kept until it ends, rather than bucketed into a calendar
    /// day.** `DayWeather` is dated at midnight in the *forecast's* zone, not
    /// the reader's, so comparing start-of-day in the reader's calendar drops
    /// the first row of a forecast for a city several hours ahead — Tokyo read
    /// from California begins the day before, locally. Asking whether the day
    /// is over instead is the same answer at home and the right one abroad,
    /// and it keeps the day in progress, which is the point: a hiker reading
    /// this at four o'clock is still deciding about this evening.
    ///
    /// Through a `Calendar` rather than by adding 86,400 seconds, for the
    /// reason the mapping gives: a real week crosses a daylight-saving
    /// boundary twice a year.
    nonisolated static func upcoming(
        in week: [Self],
        asOf date: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> [Self] {
        week.filter { day in
            guard let end = calendar.date(byAdding: .day, value: 1, to: day.date) else {
                // A calendar that cannot add a day to a date is not a reason
                // to hide the forecast; the row is kept and reads as it did.
                return true
            }
            return end > date
        }
    }
}

/// How much of the daily forecast is worth keeping.
nonisolated enum WeatherDailyPolicy {
    /// Seven days.
    ///
    /// **A decision, not the ten WeatherKit happens to send.** The question
    /// this strip answers is which day *this week* to walk, and a week is the
    /// unit that question is asked in: a Saturday nine days out is not a plan
    /// anybody is making at a trailhead, and drawing it would offer a
    /// precision the forecast does not have that far ahead. Seven also puts
    /// every weekday on screen exactly once, so whichever day it is read on,
    /// the strip covers the next weekend.
    ///
    /// It bounds the stored blob as well, the way
    /// ``WeatherHourlyPolicy/horizon`` does: what reaches
    /// ``WeatherReadingStore`` is written to `UserDefaults` on every
    /// successful fetch.
    static let horizon = 7
}

#if DEBUG
extension WeatherDaySummary {
    /// A filled week, for previews and the `--ui-test-weather` fixture.
    ///
    /// Computed rather than stored, for the reason
    /// ``WeatherHourSummary/previewStrip`` is: a `static let` is initialized
    /// once, and these days are relative to *today*. One stored at launch
    /// would hand a long simulator session a week that began yesterday.
    ///
    /// Every day differs from its neighbours in a way that is visible on
    /// screen — the high climbs and falls, and exactly one day is wet — so a
    /// row wired to the wrong value shows it rather than rendering a plausible
    /// forecast.
    static var previewWeek: [Self] {
        let start = Date.now
        return (0..<WeatherDailyPolicy.horizon).map { offset in
            Self(
                date: start.addingTimeInterval(Double(offset) * Preview.daySeconds),
                symbolName: offset == Preview.wetDay ? "cloud.rain.fill" : "cloud.sun.fill",
                highTemperature: Measurement(
                    value: Preview.highCelsius(onDay: offset),
                    unit: UnitTemperature.celsius
                ),
                lowTemperature: Measurement(
                    value: Preview.highCelsius(onDay: offset) - Preview.swingCelsius,
                    unit: UnitTemperature.celsius
                ),
                precipitationChance: offset == Preview.wetDay ? Preview.wetChance : 0
            )
        }
    }

    /// The fixture's numbers, named so the linter can tell a forecast from a
    /// row of arithmetic constants.
    private enum Preview {
        /// A fixed twenty-four hours, which is what a fixture is entitled to
        /// assume and what the mapping itself is not: a real week crosses a
        /// daylight-saving boundary, so the mapping asks a `Calendar` rather
        /// than doing arithmetic on seconds.
        static let daySeconds: TimeInterval = 86_400
        /// Far enough in that it is not the first row, which is the one a
        /// mis-indexed strip would put it in.
        static let wetDay = 2
        static let wetChance = 0.7
        static let peakCelsius: Double = 18
        static let swingCelsius: Double = 6

        /// A week that warms and cools again, so no two adjacent rows read the
        /// same.
        static func highCelsius(onDay offset: Int) -> Double {
            peakCelsius - abs(Double(offset - wetDay)) * swingCelsius / Double(wetDay)
        }
    }
}
#endif
