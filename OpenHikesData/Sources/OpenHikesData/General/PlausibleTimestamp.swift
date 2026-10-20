//
//  PlausibleTimestamp.swift
//  OpenHikes
//
//  Whether a time read out of somebody else's file can be a moment a person
//  walked.
//
//  A track's duration is its last stamp minus its first, and its date is its
//  first stamp, so one placeholder at the front of a file — the Unix epoch an
//  Android `Location.time` of zero becomes, `0001-01-01` from any .NET
//  exporter's `DateTime.MinValue`, the 1989-12-31 epoch of FIT timestamps —
//  turns a two-hour walk into one of decades and files it under the wrong
//  century. The camera and Commons paths already refuse their own year-zero
//  placeholders; this is the same refusal for the two doors a route's times
//  come in by, `GPXImport` and `CommunityRoutePayload`, written once.
//
//  A stamp that fails is treated as absent, as a non-finite elevation already
//  is: the position is what the line is made of, and the time is a field the
//  route can do without.
//

import Foundation

nonisolated public enum PlausibleTimestamp {
    private static let earliestUnixSeconds: TimeInterval = 631_152_000

    /// The first instant accepted: 1990-01-01T00:00:00Z. Early enough for any
    /// recorded GPS track, and after every placeholder named above.
    public static let earliest = Date(timeIntervalSince1970: earliestUnixSeconds)

    /// How far past `now` a stamp may be: a day, for a device whose clock is
    /// a time zone ahead of the one that is reading its file.
    public static let futureTolerance: TimeInterval = 24 * 60 * 60

    /// `date` if it can be a moment a person walked, `nil` if it cannot.
    public static func validated(_ date: Date?, now: Date = .now) -> Date? {
        // Date's derived >= and <= comparisons both accept a NaN, so the
        // window alone cannot reject every unusable timestamp.
        guard let date, date.timeIntervalSinceReferenceDate.isFinite,
              date >= earliest, date <= now.addingTimeInterval(futureTolerance)
        else { return nil }
        return date
    }
}
