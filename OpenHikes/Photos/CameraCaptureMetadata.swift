//
//  CameraCaptureMetadata.swift
//  OpenHikes
//
//  When the shutter fired, read out of what the camera reports beside the
//  frame.
//
//  `UIImagePickerController` hands its delegate two things: a `UIImage`, which
//  is pixels and nothing else, and a metadata dictionary that still carries
//  everything the camera knew — including the EXIF timestamp. Taking only the
//  image and dating the photograph `.now` dates it by the delegate callback,
//  and the callback is not the shutter: the camera shows the shot for review
//  first, and Use Photo is tapped whenever the walker gets round to it. On a
//  walk that gap is a position — ``HikePhoto/capturedAt`` is what puts the
//  picture on the elevation profile and what orders the gallery — so a photo
//  accepted a minute after it was taken would sit a minute further along the
//  route than the place it shows.
//
//  Parsed by hand rather than through a `DateFormatter`, for the reason
//  ``PhotoMetadataStamp`` builds its timestamps by hand: a `DateFormatter` is
//  not `Sendable`, so it could not be a `static let` here, and building one
//  per photograph to read six fixed-width numbers is more machinery than the
//  numbers are worth.
//

import Foundation
import ImageIO

/// The one fact worth keeping out of the camera's metadata dictionary.
nonisolated enum CameraCaptureMetadata {
    /// Where a capture time can be, in the order it is believed.
    ///
    /// `DateTimeOriginal` is the shutter and is what every iPhone capture
    /// carries. The other two are what a frame arriving from somewhere less
    /// ordinary may have instead, and both are closer to the truth than the
    /// moment the user tapped Use Photo.
    ///
    /// Held as `String` rather than as the `CFString` constants themselves,
    /// which are not `Sendable` and so cannot be a `static let` here.
    private static let sources: [(dictionary: String, key: String)] = [
        (
            kCGImagePropertyExifDictionary as String,
            kCGImagePropertyExifDateTimeOriginal as String
        ),
        (
            kCGImagePropertyExifDictionary as String,
            kCGImagePropertyExifDateTimeDigitized as String
        ),
        (
            kCGImagePropertyTIFFDictionary as String,
            kCGImagePropertyTIFFDateTime as String
        ),
    ]

    /// Three colon-separated numbers each side of the space, and the range
    /// each of them has to fall in.
    ///
    /// Checked here because the calendar checks none of it: it resolves the
    /// all-zero placeholder some cameras write into a date in the year zero,
    /// and a photograph two millennia before the walk is worse than one with
    /// no time at all.
    private static let fields = 3
    private static let months = 1...12
    private static let days = 1...31
    private static let hours = 0...23
    private static let minutes = 0...59
    /// 60 rather than 59: a leap second is a legal reading, and the calendar
    /// rolls it into the next minute rather than refusing it.
    private static let seconds = 0...60

    /// When the picture was taken, or `nil` when the camera reported no
    /// timestamp this can read.
    ///
    /// - Parameter timeZone: The zone the wall-clock reading is in. EXIF
    ///   stores no offset, so a timestamp is only ever the local time of the
    ///   device that wrote it — and that device is this one, seconds ago, so
    ///   its current zone is the right one to read it in.
    static func capturedAt(
        in properties: [String: Any],
        timeZone: TimeZone = .current
    ) -> Date? {
        for source in sources {
            guard let nested = properties[source.dictionary] as? [String: Any],
                  let text = nested[source.key] as? String,
                  let date = date(from: text, in: timeZone)
            else { continue }
            return date
        }
        return nil
    }

    /// `yyyy:MM:dd HH:mm:ss` — the only shape EXIF has for a time.
    private static func date(from text: String, in timeZone: TimeZone) -> Date? {
        let halves = text.split(separator: " ")
        guard halves.count == 2 else { return nil }
        let day = halves[0].split(separator: ":").compactMap { Int($0) }
        let time = halves[1].split(separator: ":").compactMap { Int($0) }
        guard day.count == fields, time.count == fields,
              day[0] > 0,
              months.contains(day[1]), days.contains(day[2]),
              hours.contains(time[0]), minutes.contains(time[1]),
              seconds.contains(time[2])
        else { return nil }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(
            from: DateComponents(
                year: day[0],
                month: day[1],
                day: day[2],
                hour: time[0],
                minute: time[1],
                second: time[2]
            )
        )
    }
}
