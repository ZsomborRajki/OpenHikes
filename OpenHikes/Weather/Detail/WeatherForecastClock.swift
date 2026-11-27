//
//  WeatherForecastClock.swift
//  OpenHikes
//
//  The clock a forecast is read on: its hours, the day's light and the names
//  of its days share one formatting policy. The hourly strip draws and speaks
//  one label, and the daylight rows likewise hand their drawn value to
//  VoiceOver.
//
//  The zone belongs to the forecast. The locale and hour cycle still belong
//  to the reader. Carry the zone itself rather than today's UTC offset: each
//  forecast instant may fall on a different side of a daylight-saving
//  transition.
//
//  The reader's zone is a parameter only so that a suite can pin it — see
//  *Deliberate test seams* in `AGENTS.md`. Left to the device, a test of a
//  Berlin forecast passes on a machine in Berlin with the forecast's zone
//  ignored.
//

import Foundation

nonisolated struct WeatherForecastClock: Sendable {
    /// The forecast's zone once the geocoder has said what it is — see
    /// ``WeatherPlaceNaming``.
    var forecastZone: TimeZone?
    var locale: Locale = .autoupdatingCurrent
    var readerZone: TimeZone = .autoupdatingCurrent

    /// The forecast's zone, and the reader's until that is known, which is
    /// the fallback the day rows take.
    var zone: TimeZone { forecastZone ?? readerZone }

    /// The hour the strip draws and speaks, in the reader's hour cycle.
    func hour(_ date: Date) -> String {
        date.formatted(style().hour())
    }

    /// Sunrise, sunset and civil dusk keep the reader's short clock format.
    func time(_ date: Date) -> String {
        date.formatted(style(time: .shortened))
    }

    private func style(time: Date.FormatStyle.TimeStyle = .omitted) -> Date.FormatStyle {
        Date.FormatStyle(date: .omitted, time: time, locale: locale, timeZone: zone)
    }
}

// MARK: - The names of its days

nonisolated extension WeatherForecastClock {
    /// The day's name as the row draws it, or "Today" for the day in progress.
    ///
    /// The word rather than the weekday for today, because the forecast keeps
    /// the day in progress and "Sat" in the first row of a forecast read on
    /// Saturday afternoon is a question rather than an answer.
    ///
    /// Abbreviated below that: seven full weekday names down a sheet is a
    /// column of text where the point is the numbers beside it.
    ///
    /// Formatted in `timeZone`, the forecast's, because `date` is midnight
    /// there: read in the reader's zone, Tokyo's Friday is Thursday afternoon
    /// in Berlin, and every row is a weekday early.
    static func weekday(_ date: Date, isToday: Bool, in timeZone: TimeZone) -> String {
        isToday ? today : date.formatted(Date.FormatStyle(timeZone: timeZone).weekday(.abbreviated))
    }

    /// The same day, spelled out, which is what the row is called aloud.
    ///
    /// The abbreviation is a layout decision and nothing else: VoiceOver
    /// reading "Sat" is the screen's shorthand read back rather than the day
    /// it stands for, and a reader stepping down seven rows is the one person
    /// here with no column of numbers to line it up against.
    static func spokenWeekday(_ date: Date, isToday: Bool, in timeZone: TimeZone) -> String {
        isToday ? today : date.formatted(Date.FormatStyle(timeZone: timeZone).weekday(.wide))
    }

    /// The one word both spellings of a weekday share, for the day in
    /// progress — see ``WeatherDaySummary/isInProgress(asOf:)``.
    private static var today: String {
        String(localized: "Today", comment: "The first row of the daily forecast")
    }
}

extension WeatherDetailView {
    /// The clock this sheet's forecast is read on.
    func forecastClock(
        locale: Locale = .autoupdatingCurrent,
        readerZone: TimeZone = .autoupdatingCurrent
    ) -> WeatherForecastClock {
        WeatherForecastClock(forecastZone: weather.forecastTimeZone, locale: locale, readerZone: readerZone)
    }
}
