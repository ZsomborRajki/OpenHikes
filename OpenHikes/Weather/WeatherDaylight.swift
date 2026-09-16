//
//  WeatherDaylight.swift
//  OpenHikes
//
//  How much daylight is left, which is the weather fact a walk is planned
//  around.
//
//  `.current` and `.hourly` answer "what is it doing now and for the next
//  twelve hours", which is what #403 set out to fix and did. Neither answers
//  the question a hiker at a trailhead at four o'clock is actually asking.
//  `.daily` carries it, costs no extra round trip — `weather(for:including:)`
//  is variadic — and brings the day's high and low with it, which the sheet
//  could not show at all.
//
//  ## Why every field is optional
//
//  **There are places with no sunrise and no sunset, and people hike in
//  them.** Above the Arctic Circle in June `sun.sunset` is `nil`, and it is
//  `nil` again in December for the opposite reason. Northern Norway, Iceland
//  and Swedish Lappland are hiking destinations rather than edge cases, so an
//  absent sunset is a fact to draw rather than a failure to handle — and a
//  non-optional field with a sentinel date would be a lie in the one place
//  where the truth is the most interesting thing on the screen.
//
//  ## Civil dusk as well as sunset
//
//  Sunset is when the sun goes behind the horizon; civil dusk is when there
//  stops being enough light to walk by, and in the mountains those are
//  twenty-five to forty minutes apart. A hiker deciding whether to push on to
//  the next hut is asking about the second one. Both are drawn because neither
//  alone is honest: sunset is the one people plan by and civil dusk is the one
//  that ends the walk.
//

import Foundation
import WeatherKit

/// The day's light and its temperature range, from `.daily`.
///
/// A value with no framework in it, for the reason ``WeatherConditions`` is
/// one: it crosses actors, it is restored from a stored blob as readily as
/// from a response, and a suite or a preview can build one without an
/// entitlement.
nonisolated struct WeatherDaylight: Equatable, Sendable {
    /// `nil` where the sun does not rise or set that day — see this file's
    /// header.
    var sunrise: Date?
    var sunset: Date?
    /// When there stops being enough light to walk by, which is the later of
    /// the two and the one that ends a hike.
    var civilDusk: Date?
    /// The day's forecast range, which `.current` alone cannot give.
    var highTemperature: Measurement<UnitTemperature>?
    var lowTemperature: Measurement<UnitTemperature>?

    /// Whether there is anything at all to draw.
    ///
    /// A day inside the Arctic summer has no sunrise, no sunset and no civil
    /// dusk, and a section drawn for it would be three empty rows under a
    /// heading. The temperatures are excluded from the question on purpose:
    /// they belong to the *conditions* the sheet already draws rather than to
    /// the daylight this section is about, so a reading carrying only a high
    /// and a low has nothing to say here.
    var hasDaylightTimes: Bool {
        sunrise != nil || sunset != nil || civilDusk != nil
    }

    /// How long until the light goes, measured from `date`.
    ///
    /// Civil dusk rather than sunset, for the reason the header gives: this is
    /// the number a hiker decides on. `nil` when there is no dusk to count
    /// towards, and **`nil` rather than a negative interval once it has
    /// passed** — "−40 minutes of daylight" is not a thing to put on a screen,
    /// and the row that reads this draws the time itself instead.
    func remainingLight(asOf date: Date) -> TimeInterval? {
        guard let civilDusk else { return nil }
        let remaining = civilDusk.timeIntervalSince(date)
        return remaining > 0 ? remaining : nil
    }
}

extension WeatherDaylight {
    /// The one place WeatherKit's daily shape is read.
    ///
    /// `nonisolated` for the reason ``WeatherConditions``' own mapping is: the
    /// caller is a nonisolated initializer on a value that has to cross
    /// actors.
    ///
    /// **The day the reading is about, not the first day of the forecast.**
    /// `.daily` begins at today and runs for ten days; picking `.first` is
    /// right until a reading is restored near midnight, when the stored blob's
    /// day and the forecast's first day are not the same day. Matched against
    /// `capturedAt` in the current calendar, which is also what makes "today's
    /// sunset" mean today's.
    ///
    /// `nil` when nothing in the forecast covers that day, which is what a
    /// provider with no daily data for the point answers — the same shape an
    /// empty hourly strip takes.
    nonisolated static func forDay(
        of date: Date,
        in forecast: Forecast<DayWeather>,
        calendar: Calendar = .autoupdatingCurrent
    ) -> Self? {
        guard let day = forecast.first(where: { calendar.isDate($0.date, inSameDayAs: date) })
            ?? forecast.first
        else { return nil }
        return Self(
            sunrise: day.sun.sunrise,
            sunset: day.sun.sunset,
            civilDusk: day.sun.civilDusk,
            highTemperature: day.highTemperature,
            lowTemperature: day.lowTemperature
        )
    }
}
