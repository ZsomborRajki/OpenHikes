//
//  WeatherDetailView+Clock.swift
//  OpenHikes
//
//  The hourly strip and the day's light share a clock-formatting policy.
//  The strip draws and speaks one label; the daylight rows likewise hand
//  their drawn value to VoiceOver through DetailRow.
//
//  The zone belongs to the forecast, as it already does for weekday names.
//  The locale and hour cycle still belong to the reader. Carry the zone
//  itself rather than today's UTC offset: each forecast instant may fall on
//  a different side of a daylight-saving transition.
//

import Foundation

extension WeatherDetailView {
    /// The hour the strip draws and speaks, in the reader's hour cycle.
    func forecastHour(_ date: Date, locale: Locale = .autoupdatingCurrent) -> String {
        date.formatted(forecastClockStyle(locale: locale).hour())
    }

    /// Sunrise, sunset and civil dusk keep the reader's short clock format.
    func forecastTime(_ date: Date, locale: Locale = .autoupdatingCurrent) -> String {
        date.formatted(forecastClockStyle(locale: locale, time: .shortened))
    }

    private func forecastClockStyle(
        locale: Locale,
        time: Date.FormatStyle.TimeStyle = .omitted
    ) -> Date.FormatStyle {
        Date.FormatStyle(
            date: .omitted,
            time: time,
            locale: locale,
            timeZone: weather.forecastTimeZone ?? .autoupdatingCurrent
        )
    }
}
