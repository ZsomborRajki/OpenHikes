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
//  The reader's zone is a parameter only so that a suite can pin it — see
//  *Deliberate test seams* in `AGENTS.md`. Left to the device, a test of a
//  Berlin forecast passes on a machine in Berlin with the forecast's zone
//  ignored.
//

import Foundation

extension WeatherDetailView {
    /// The hour the strip draws and speaks, in the reader's hour cycle.
    func forecastHour(
        _ date: Date,
        locale: Locale = .autoupdatingCurrent,
        readerZone: TimeZone = .autoupdatingCurrent
    ) -> String {
        date.formatted(forecastClockStyle(locale: locale, readerZone: readerZone).hour())
    }

    /// Sunrise, sunset and civil dusk keep the reader's short clock format.
    func forecastTime(
        _ date: Date,
        locale: Locale = .autoupdatingCurrent,
        readerZone: TimeZone = .autoupdatingCurrent
    ) -> String {
        date.formatted(forecastClockStyle(locale: locale, readerZone: readerZone, time: .shortened))
    }

    /// The forecast's zone once the geocoder has said what it is, and the
    /// reader's until then, which is the fallback the day rows take.
    private func forecastClockStyle(
        locale: Locale,
        readerZone: TimeZone,
        time: Date.FormatStyle.TimeStyle = .omitted
    ) -> Date.FormatStyle {
        Date.FormatStyle(
            date: .omitted,
            time: time,
            locale: locale,
            timeZone: weather.forecastTimeZone ?? readerZone
        )
    }
}
