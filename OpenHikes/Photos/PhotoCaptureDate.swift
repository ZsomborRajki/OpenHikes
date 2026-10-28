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

import Foundation

nonisolated enum PhotoCaptureDate {
    private static let hours = 0...23
    private static let minutes = 0...59
    private static let seconds = 0...60

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
}
