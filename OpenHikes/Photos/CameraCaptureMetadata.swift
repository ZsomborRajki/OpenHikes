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
//  first, and Use Photo is tapped whenever the hiker gets round to it. On a
//  walk that gap is a position — ``HikePhoto/capturedAt`` is what puts the
//  picture on the elevation profile and what orders the gallery — so a photo
//  accepted a minute after it was taken would sit a minute further along the
//  route than the place it shows.
//
//  Parsed by hand rather than through a date parser, and not for the reason
//  a comment here used to give: it said `DateFormatter` is not `Sendable`,
//  which the SDK contradicts — `NSDateFormatter.h` declares
//  `NS_SWIFT_SENDABLE`. The real reason is the validation directly below.
//  A calendar can resolve EXIF's all-zero placeholder or an impossible day
//  into a real date, and an invented capture time is worse than none. Keep
//  all six numeric fields intact and validate them through PhotoCaptureDate
//  before accepting the reading.
//

import Algorithms
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
        sources.firstNonNil { source in
            guard let nested = properties[source.dictionary] as? [String: Any],
                  let text = nested[source.key] as? String
            else { return nil }
            return date(from: text, in: timeZone)
        }
    }

    /// `yyyy:MM:dd HH:mm:ss` — the only shape EXIF has for a time.
    private static func date(from text: String, in timeZone: TimeZone) -> Date? {
        let halves = text.split(separator: " ")
        guard halves.count == 2,
              let day = halves[0].wholeMatch(of: #/([0-9]{4}):([0-9]{2}):([0-9]{2})/#),
              let clock = halves[1].wholeMatch(of: #/([0-9]{2}):([0-9]{2}):([0-9]{2})/#)
        else { return nil }
        return PhotoCaptureDate.date(
            from: DateComponents(
                year: Int(day.1),
                month: Int(day.2),
                day: Int(day.3),
                hour: Int(clock.1),
                minute: Int(clock.2),
                second: Int(clock.3)
            ),
            in: timeZone
        )
    }
}
