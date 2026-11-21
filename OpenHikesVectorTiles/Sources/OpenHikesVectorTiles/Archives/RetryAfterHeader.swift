//
//  RetryAfterHeader.swift
//  OpenHikesVectorTiles
//
//  When a server has told us, in so many words, how long to stay away: the
//  reading of `Retry-After`, for ``VectorTileClient`` and for every other
//  request the host makes of a server that may send one. In OpenHikes that
//  is the raster tile servers (`TileRetryAdvice`) and Overpass, which read it
//  from here rather than keep a second reader.
//

import Foundation

/// Reads `Retry-After` off a response.
public enum RetryAfterHeader {
    public static let name = "Retry-After"

    public static let tooManyRequests = 429
    public static let serviceUnavailable = 503

    /// The statuses whose `Retry-After` is worth honouring.
    ///
    /// 429 is the rate limit itself; 503 is what a tile server returns when
    /// it is shedding load, and OSM's infrastructure uses both. A 404 or a
    /// 500 may carry the header too, but neither says anything about *this*
    /// client's request rate, so neither should be allowed to park a tile.
    public static let honoredStatusCodes: Set<Int> = [tooManyRequests, serviceUnavailable]

    /// Longest delay honoured. A header asking for a day — or a misparsed
    /// date that looks like one — must not take a tile off the map until the
    /// app is relaunched. Fifteen minutes is already three times the ceiling
    /// of OpenHikes' own backoff for a failed tile (`TileRetryPolicy`, in the
    /// app), so anything past it is answering a question about server
    /// capacity that a reconnect or a relaunch will re-ask anyway.
    public static let maximumDelay: Duration = .seconds(15 * 60)

    /// How long `value` asks the client to wait, or `nil` when it asks for
    /// nothing usable.
    ///
    /// RFC 9110 allows two spellings: delta-seconds, and an HTTP-date. Only
    /// the IMF-fixdate form of the latter is parsed — the RFC 850 and asctime
    /// forms are obsolete and no tile server sends them — and a value in
    /// neither form is treated as no advice at all rather than as a reason to
    /// guess.
    ///
    /// A deadline already in the past, or a delay of zero, is `nil` rather
    /// than `.zero`: it would lower the floor to nothing, and the caller's own
    /// backoff is what should decide then.
    public static func delay(from value: String, now: Date = Date()) -> Duration? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        if let seconds = Int(trimmed) {
            return clamped(.seconds(seconds))
        }
        guard let date = httpDate(trimmed) else { return nil }
        let interval = date.timeIntervalSince(now)
        guard interval.isFinite else { return nil }
        return clamped(.seconds(interval))
    }

    /// The advice in `response`, if it is a status that carries any.
    public static func delay(from response: HTTPURLResponse, now: Date = Date()) -> Duration? {
        guard honoredStatusCodes.contains(response.statusCode),
              let value = response.value(forHTTPHeaderField: name)
        else { return nil }
        return delay(from: value, now: now)
    }

    private static func clamped(_ delay: Duration) -> Duration? {
        guard delay > .zero else { return nil }
        return min(delay, maximumDelay)
    }

    /// The IMF-fixdate reader, configured once.
    ///
    /// This used to build a `DateFormatter` per call, on the stated grounds
    /// that `DateFormatter` is not `Sendable` and so could not be held in a
    /// `static let`. That was never true of this SDK — `NSDateFormatter.h`
    /// declares `NS_SWIFT_SENDABLE`, "all mutable state protected by locks" —
    /// and a `Date.ParseStrategy` is a value type, so the question does not
    /// arise at all.
    ///
    /// Field for field the same grammar `"EEE, dd MMM yyyy HH:mm:ss zzz"`
    /// expressed, with `.specificName(.short)` standing in for `zzz`: `GMT`
    /// and `UTC` are read, a named zone that is not one of them is refused,
    /// and `zzz`'s tolerance of `+0000` is kept. Not a `Date.FormatStyle`,
    /// which is a localized rendering of a date for a person to read, where
    /// this is a wire format that is the same in every locale.
    private static let imfFixdate = Date.ParseStrategy(
        format: """
        \(weekday: .abbreviated), \(day: .twoDigits) \(month: .abbreviated) \
        \(year: .padded(4)) \
        \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\
        \(minute: .twoDigits):\(second: .twoDigits) \
        \(timeZone: .specificName(.short))
        """,
        locale: Locale(identifier: "en_US_POSIX"),
        timeZone: .gmt,
        isLenient: false
    )

    /// Matched whole rather than parsed from the front: `parse(_:)` stops as
    /// soon as it has a date and would read `…07:28:00 GMT and change` as a
    /// deadline, where the formatter this replaced refused it. The header's
    /// value is the date or it is not advice.
    private static func httpDate(_ value: String) -> Date? {
        value.wholeMatch(of: imfFixdate)?.output
    }
}
