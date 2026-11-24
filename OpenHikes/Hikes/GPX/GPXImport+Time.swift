//
//  GPXImport+Time.swift
//  OpenHikes
//
//  How a GPX `<time>` is read. Split from the parser for length.
//

import Foundation
import OpenHikesData

nonisolated extension GPXImport {
    /// Reads a GPX `<time>`, as strictly as the format asks and as leniently
    /// as the files people have need.
    ///
    /// GPX 1.1 says a `<time>` is UTC and carries a designator, and the two
    /// strict strategies are that file. The local pair is for the files
    /// people actually have: exporters that write `2020-01-01T10:00:00`
    /// with no `Z` and no offset are common enough that refusing them
    /// costs the hike its duration, both its speeds and its date — a whole
    /// track's worth of timestamps discarded over a missing letter.
    ///
    /// Read as the device's own time rather than as UTC. Both are guesses
    /// and both are wrong by the same offset when the guess is wrong; what
    /// decides it is that an exporter omitting the designator is writing
    /// wall-clock time, so reading it locally is the one that shows the
    /// hiker the hour their own file says. Last because the lenient
    /// grammar also accepts a string that *does* carry a designator and
    /// would quietly ignore it.
    struct TimeReader {
        private let fractionalDateStrategy = Date.ISO8601FormatStyle(
            includingFractionalSeconds: true
        )
        private let dateStrategy = Date.ISO8601FormatStyle()
        /// The same grammar with the zone designator taken out of it, so what
        /// the string omits is supplied by the device instead.
        private let localDateStrategy = Self.localStyle(includingFractionalSeconds: true)
        /// And without the fraction, as the strict pair has it. iOS 26's
        /// parser lets a style's fraction be left out of the string; iOS 18's
        /// requires it, so below 26 a whole-second time with no designator
        /// is read by this one or not at all.
        private let localWholeSecondDateStrategy = Self.localStyle(includingFractionalSeconds: false)

        private static func localStyle(includingFractionalSeconds: Bool) -> Date.ISO8601FormatStyle {
            Date.ISO8601FormatStyle(timeZone: .autoupdatingCurrent)
                .year()
                .month()
                .day()
                .dateSeparator(.dash)
                .dateTimeSeparator(.standard)
                .time(includingFractionalSeconds: includingFractionalSeconds)
        }

        func date(from value: String) -> Date? {
            guard !value.isEmpty else { return nil }
            // A placeholder parses as readily as a real time, and one at the
            // front of a file makes the walk decades long; see
            // ``PlausibleTimestamp``. Here rather than at each caller because
            // the metadata time and every point's time come through this.
            return PlausibleTimestamp.validated(
                (try? fractionalDateStrategy.parse(value))
                    ?? (try? dateStrategy.parse(value))
                    ?? (try? localDateStrategy.parse(value))
                    ?? (try? localWholeSecondDateStrategy.parse(value))
            )
        }
    }
}
