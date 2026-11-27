//
//  WeatherToday.swift
//  OpenHikes
//
//  The day the weather sheet calls today, and whether the reading it opens
//  on was taken during it.
//
//  Two parts of the sheet speak of today: the head gives the day's high and
//  low under the temperature, and *Next days* names a row *Today* and marks
//  the temperature on its bar. Both read this, so they cannot disagree.
//
//  Today is the forecast day the sheet is drawn in, not the one the reading
//  was taken in. Nothing in ``WeatherManager`` expires, so a reading taken
//  at 23:50 can still be the newest at 00:10, and by then its day has
//  ended: the days panel has already moved on (see
//  ``WeatherDaySummary/upcoming(in:asOf:calendar:)``), and a head still
//  giving yesterday's range would sit over a *Today* row giving another.
//  The reading's own temperature is the one thing that stays yesterday's,
//  so it is marked on today's bar only when it was taken today.
//
//  A day runs from its start to the next day's start, as
//  ``WeatherForecastDay`` has it, in the forecast's own zone.
//

import Foundation

nonisolated struct WeatherToday: Equatable, Sendable {
    /// The forecast day in progress.
    let day: WeatherDaySummary
    /// Whether the reading was taken during ``day``, which is when its
    /// temperature belongs on the day's bar.
    let holdsReading: Bool

    /// `nil` when no day of `week` is in progress as of `date`: the week has
    /// not begun, or every day of it has ended.
    init?(week: [WeatherDaySummary], asOf date: Date, readingTakenAt takenAt: Date, calendar: Calendar) {
        let starts = week.map(\.date)
        guard let index = WeatherForecastDay.index(containing: date, startingAt: starts, calendar: calendar) else {
            return nil
        }
        day = week[index]
        holdsReading = WeatherForecastDay.index(containing: takenAt, startingAt: starts, calendar: calendar) == index
    }
}
