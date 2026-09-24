//
//  GPXImport+Limits.swift
//  OpenHikes
//
//  What a picked file may cost, and why one did not become a hike. Split from
//  the parser for length; both are read by the importer, the inbox and the
//  alert, none of which needs the XML half.
//

import Foundation

nonisolated extension GPXImport {
    /// What one picked file is allowed to cost.
    ///
    /// The app has no say in what arrives here. A file the user chose from
    /// Files at least passed under their eyes first; one delivered through
    /// `Documents/Inbox` — AirDrop, a mail attachment, a share extension —
    /// was chosen by somebody else and is read unattended, so these two
    /// numbers are the only thing standing between the import and however
    /// much memory the sender felt like spending.
    ///
    /// Two bounds because neither implies the other: the byte cap bounds the
    /// single allocation `Data(contentsOf:)` makes, while the point cap bounds
    /// the arrays the parse grows out of those bytes, which a file written
    /// without whitespace or elevations can fill from far fewer of them.
    ///
    /// Taken as a parameter rather than read as a constant only so the suite
    /// can drive both bounds directly instead of having to serialize a file
    /// large enough to reach the shipping ones; every caller in the app takes
    /// ``standard``.
    struct Limits: Sendable, Equatable {
        var maximumFileSizeBytes: Int
        var maximumPointCount: Int
        /// How many hikes one file may become. A file that holds more is
        /// refused as ``ImportFailure/tooLarge`` rather than turned into a
        /// library's worth of rows from one tap — see ``loadAll(from:limits:)``.
        var maximumTrackCount = standardTrackCount

        /// Sized against the largest file a hiker could plausibly own, not
        /// against the smallest one that would still work.
        ///
        /// A day out recorded at 1 Hz is roughly 20,000 track points and a
        /// little over 2 MB; the same points carrying Garmin's or Strava's
        /// `<extensions>` (heart rate, cadence, temperature) are nearer 6 MB.
        /// 32 MB is well over an order of magnitude above a day's walk, so
        /// nothing anybody would recognise as one of their own hikes comes
        /// near it, and reading plus parsing a file at the cap still peaks
        /// inside what iOS lets a foreground app hold. Half a million points
        /// is around 140 hours of 1 Hz fixes — more than any single track is —
        /// and is what a file that spends all its bytes on points runs into
        /// first.
        ///
        /// Both are deliberately loose. A cap that refuses a real hike is a
        /// worse failure than one that lets an absurd file through, because
        /// the hiker with the real hike has no way to get it in.
        static let standard = Self(
            maximumFileSizeBytes: standardFileSizeBytes,
            maximumPointCount: standardPointCount
        )

        private static let standardFileSizeBytes = 32 * 1024 * 1024
        private static let standardPointCount = 500_000
        /// A fortnight's hut-to-hut trek exported a day to a track, three
        /// times over; a region's guidebook download of walks is a few dozen.
        /// Past this a file is an archive rather than a trip.
        static let standardTrackCount = 50
    }

    /// Why a file couldn't be turned into a hike.
    ///
    /// Worth distinguishing rather than collapsing to "import failed": each
    /// means something genuinely different to whoever picked the file, and
    /// sends them somewhere different to fix it. The import used to say nothing
    /// at all — a picked file that produced no hike looked exactly like a
    /// picked file that was ignored.
    ///
    /// `CaseIterable` so the suite can walk every case and insist it carries
    /// copy: a case added here without a sentence to show is an empty alert,
    /// and a hand-written list of cases in a test cannot notice the omission.
    enum ImportFailure: LocalizedError, CaseIterable, Equatable, Sendable {
        /// More than one `<trk>` (or more than one `<rte>`) carrying usable
        /// points, and none of them chosen.
        ///
        /// Each is a separate activity, and a hike here holds exactly one
        /// route, so such a file becomes one hike per track — see
        /// ``loadAll(from:limits:)`` and ``GPXTrackChoice``. What is left of
        /// this case is the hiker cancelling that choice, and
        /// ``load(from:limits:)``, which answers for exactly one track.
        /// Joining them would invent a leg between two places nobody
        /// travelled between, so neither path ever does.
        case multipleTracks
        /// Parsed, but nothing in it carried a coordinate this app can project
        /// — no points at all, points missing `lat`/`lon`, or points outside
        /// Web Mercator's range.
        case noUsablePoints
        /// Past one of ``Limits``. Refused before the bytes are read where the
        /// file system will say how big the file is, and mid-parse where it
        /// won't.
        case tooLarge
        /// One usable point. Enough to put a pin on a map; not a route — no
        /// length, no elevation profile, nothing to draw. Policy rather than a
        /// parse failure, so ``load(from:limits:)`` still returns such a track
        /// and the import is what refuses it.
        case tooShort
        /// Not there, or not well-formed XML — the parser had nothing to work
        /// with. Note that well-formed XML that simply *isn't* GPX (an HTML
        /// page, say) parses happily into an empty document, so it arrives as
        /// ``noUsablePoints`` instead; the copy for that case allows for it.
        case unreadable

        var errorDescription: String? {
            switch self {
            case .multipleTracks: "This GPX file holds more than one track."
            case .noUsablePoints: "No track points were found in this file."
            case .tooLarge: "This GPX file is too large to import."
            case .tooShort: "This GPX file has only one track point."
            case .unreadable: "This file couldn't be read."
            }
        }

        var recoverySuggestion: String? {
            switch self {
            // Never raised by the screen — cancelling the choice is the
            // hiker's own answer — so this is read only where a caller cannot
            // ask, ``HikeImport/hike(from:into:save:)``, and says what the
            // asking path would have done.
            case .multipleTracks: "Each track imports as a hike of its own. Choose at least one to import the file."
            // Deliberately covers "it isn't GPX at all" as well — see the case's
            // own note for why that lands here.
            case .noUsablePoints: "It may not be a GPX file, or its points are missing coordinates or out of range."
            // No number in the copy: the message has to be true of both bounds,
            // and the hiker can act on it without knowing which one was hit.
            case .tooLarge: "A single hike is a few megabytes at most, and a file holds a few dozen tracks at most. "
                + "This one is past what can be imported at once."
            case .tooShort: "A hike needs at least two points to have a route."
            case .unreadable: "Check that it's a .gpx file and isn't damaged."
            }
        }
    }
}
