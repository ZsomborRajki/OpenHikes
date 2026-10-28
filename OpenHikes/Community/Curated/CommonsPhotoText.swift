//
//  CommonsPhotoText.swift
//  OpenHikes
//
//  Reading the three things a Commons file page says in words: its licence,
//  who took it, and when.
//
//  None of the three is structured on Commons. The licence is a short name a
//  template wrote, the author is whatever HTML the uploader typed — a user
//  link, a name, a museum, a sentence — and the date is a string that is a
//  camera's EXIF time on one file and "between 1900 and 1910" on the next. So
//  each is read here, by a rule small enough to state and to test, and a field
//  the rule cannot read is treated as absent rather than shown as it came.
//

import Foundation
import OpenHikesData

/// Which licences a Commons photograph may be under for this app to show it.
nonisolated enum CommonsLicense {
    /// The short names kept, as the start of `LicenseShortName`.
    ///
    /// Every Creative Commons attribution licence in every version and port
    /// (`CC BY 2.0`, `CC BY-SA 3.0 de`, `CC BY-SA 4.0`), CC0, and the public
    /// domain: the licences whose terms are a credit and a link, which is what
    /// every gallery page and saved copy gives. What is left out is everything
    /// that asks for more than that — the GFDL wants its full text carried
    /// with the copy — and anything this list does not recognise, which is
    /// the safe direction to be wrong in.
    private static let acceptedPrefixes = ["CC BY", "CC0", "Public domain"]

    /// The non-commercial and no-derivatives clauses, which Commons does not
    /// accept and this app must not show, checked anyway: the answer is a
    /// string somebody's template wrote.
    private static let refusedClauses = ["-NC", "-ND"]

    /// `name`, trimmed, when it is a licence this app may show photographs
    /// under — or `nil`.
    static func accepted(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard acceptedPrefixes.contains(where: { trimmed.hasPrefix($0) }),
              !refusedClauses.contains(where: { trimmed.contains($0) })
        else { return nil }
        return trimmed
    }
}

/// Plain text out of the HTML Commons puts in a metadata field.
nonisolated enum CommonsText {
    /// The namespaces a user link carries in its text. "User:Anna" is a page
    /// title; the person is "Anna".
    private static let userPrefixes = ["User:", "Benutzer:"]

    /// The entities that turn up in author fields, and what each stands for.
    /// Numeric ones are decoded separately.
    ///
    /// In order, with `&amp;` last: decoded first, it would turn an escaped
    /// `&amp;lt;` into a `&lt;` the next pass reads as `<`. A dictionary has
    /// no order of its own, so it decoded those twice on some launches and
    /// once on others.
    private static let namedEntities = [
        ("&apos;", "'"), ("&gt;", ">"), ("&lt;", "<"), ("&nbsp;", " "), ("&quot;", "\""), ("&amp;", "&"),
    ]

    /// The author an `Artist` field names, as a credit — or `nil` when it names
    /// nobody that can be read.
    ///
    /// Tags are stripped and entities decoded, a user page's namespace is
    /// dropped, whitespace is collapsed, and the result is bounded like any
    /// other name that arrives unattended — see ``BoundedText``. A field that
    /// is a whole paragraph is cut rather than refused: the first words of it
    /// are still who took the picture.
    static func author(_ html: String?) -> String? {
        guard let html else { return nil }
        var text = plain(html)
        for prefix in userPrefixes where text.hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count))
        }
        return BoundedText.bounded(text, to: .credit)
    }

    /// A licence link as a URL, completing the scheme-relative `//host/path`
    /// form Commons writes some of them in.
    static func link(_ text: String) -> URL? {
        let trimmed = plain(text)
        guard !trimmed.isEmpty else { return nil }
        let absolute = trimmed.hasPrefix("//") ? "https:" + trimmed : trimmed
        guard let url = URL(string: absolute), url.scheme?.hasPrefix("http") == true else { return nil }
        return url
    }

    /// `html` as one line of plain text.
    static func plain(_ html: String) -> String {
        let untagged = html.replacing(#/<[^>]*>/#, with: " ")
        var decoded = untagged.replacing(#/&#(x?)([0-9A-Fa-f]+);/#) { match in
            let radix = match.1.isEmpty ? 10 : 16
            guard let value = UInt32(match.2, radix: radix),
                  let scalar = Unicode.Scalar(value)
            else { return "" }
            return String(Character(scalar))
        }
        for (entity, character) in namedEntities {
            decoded = decoded.replacing(entity, with: character)
        }
        return decoded
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}

/// When a Commons photograph was taken.
nonisolated enum CommonsDate {
    /// Nothing before the first photographs. Calendar, clock and offset
    /// validity are shared with the camera through ``PhotoCaptureDate``.
    private static let earliestYear = 1826

    /// The capture time `DateTimeOriginal` gives, or the upload time when it
    /// gives none this can read.
    ///
    /// The upload is the honest fallback rather than a guess: the picture
    /// existed by then, and a scan of an old postcard dated by its upload
    /// says *no later than this* rather than inventing a day. `nil` only when
    /// neither can be read, and such a file is left out — a photograph has to
    /// be dated to be a ``HikePhoto``.
    ///
    /// - Parameter timeZone: The zone a reading with none is in. A camera's
    ///   EXIF time carries no zone, and the photographs here were taken
    ///   somewhere near the trail; the device's own zone is the reading
    ///   ``CameraCaptureMetadata`` makes for the same reason.
    static func capturedAt(_ original: String?, uploaded: String?, timeZone: TimeZone) -> Date? {
        original.flatMap { date(from: $0, in: timeZone) }
            ?? uploaded.flatMap { try? Date.ISO8601FormatStyle().parse($0) }
    }

    /// One of the shapes `DateTimeOriginal` takes: `2013-08-03 12:34:56`, its
    /// EXIF spelling with colons in the date, `2013-08-03T12:34:56`, a date
    /// alone, or any of those inside `<time datetime="…">`. The ISO form may
    /// also end in `Z` or a `±HH:mm` offset, and is then read in that zone.
    /// Anything else — another suffix, a fraction of a second, a missing or
    /// broken field, a day the calendar does not have — refuses the whole
    /// reading, and ``capturedAt(_:uploaded:timeZone:)`` falls back to the
    /// upload.
    static func date(from text: String, in timeZone: TimeZone) -> Date? {
        let reading = text.firstMatch(of: #/datetime="([^"]+)"/#).map { String($0.1) }
            ?? CommonsText.plain(text)
        let halves = reading.split(
            omittingEmptySubsequences: false, whereSeparator: { $0 == " " || $0 == "T" }
        )
        guard halves.count == 1 || halves.count == 2,
              let day = halves[0].wholeMatch(of: #/([0-9]{4})([-:])([0-9]{2})\2([0-9]{2})/#),
              let year = Int(day.1), year >= earliestYear
        else { return nil }
        var components = DateComponents(
            year: year, month: Int(day.3), day: Int(day.4), hour: 0, minute: 0, second: 0
        )
        var zone = timeZone
        if halves.count == 2 {
            let shape = #/([0-9]{2}):([0-9]{2}):([0-9]{2})(Z|[+-][0-9]{2}:[0-9]{2})?/#
            guard let clock = halves[1].wholeMatch(of: shape) else { return nil }
            components.hour = Int(clock.1)
            components.minute = Int(clock.2)
            components.second = Int(clock.3)
            if let offset = clock.4 {
                guard day.2 == "-", reading.contains("T"), let explicitZone = Self.zone(from: offset)
                else { return nil }
                zone = explicitZone
            }
        }
        return PhotoCaptureDate.date(from: components, in: zone)
    }

    private static func zone(from offset: Substring) -> TimeZone? {
        offset == "Z" ? .gmt : PhotoCaptureDate.zone(fromOffset: String(offset))
    }
}
