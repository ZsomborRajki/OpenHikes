//
//  PhotoCaptureDate.swift
//  OpenHikes
//
//  The calendar boundary shared by camera EXIF and Commons capture metadata.
//  Calendar.date(from:) normalizes an impossible day into another month, so
//  constructing a Date is not validation. Check the Gregorian day first and
//  keep the clock's deliberate exception separate: 60 seconds is accepted as
//  a leap-second reading and rolls into the next minute.
//
//  An offset is the same kind of boundary: `TimeZone(secondsFromGMT:)` makes
//  a zone of any offset up to 18 hours, including ones no place keeps, so the
//  bound on a real one is checked here.
//

import Foundation

nonisolated enum PhotoCaptureDate {
    private static let hours = 0...23
    private static let minutes = 0...59
    private static let seconds = 0...60
    /// The widest UTC offsets in use, and the shape of the minutes beside them.
    private static let offsetHours = 0...14
    private static let offsetMinutes = 0...59
    private static let minutesPerHour = 60
    private static let secondsPerMinute = 60

    /// Complete numeric fields naming a real day, read in the supplied zone.
    static func date(from components: DateComponents, in timeZone: TimeZone) -> Date? {
        guard let year = components.year, year > 0,
              let month = components.month, let day = components.day,
              let hour = components.hour, hours.contains(hour),
              let minute = components.minute, minutes.contains(minute),
              let second = components.second, seconds.contains(second)
        else { return nil }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let date = DateComponents(year: year, month: month, day: day)
        guard date.isValidDate(in: calendar) else { return nil }
        return calendar.date(from: components)
    }

    /// `±HH:MM`, the spelling EXIF's `OffsetTimeOriginal` and an ISO reading
    /// share, as a zone — or `nil` for any other spelling, and for an offset
    /// wider than any zone's.
    static func zone(fromOffset text: String) -> TimeZone? {
        guard let fields = text.wholeMatch(of: #/([+-])([0-9]{2}):([0-9]{2})/#),
              let hour = Int(fields.2), offsetHours.contains(hour),
              let minute = Int(fields.3), offsetMinutes.contains(minute)
        else { return nil }
        let sign = fields.1 == "+" ? 1 : -1
        return TimeZone(secondsFromGMT: sign * (hour * minutesPerHour + minute) * secondsPerMinute)
    }
}
