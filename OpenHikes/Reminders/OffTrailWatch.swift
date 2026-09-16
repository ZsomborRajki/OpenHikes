//
//  OffTrailWatch.swift
//  OpenHikes
//
//  Whether being off the line has lasted long enough to be worth saying, and
//  whether it has already been said.
//
//  ``MovementWatch`` next door answers the opposite question — a *paused*
//  subject that has started moving — and the two deliberately do not share a
//  state machine, because the rule about repeating is the other way round. A
//  pause that keeps moving is told up to ``MovementReminderPolicy/
//  maximumReminders`` times, on the argument that the hiker may not have seen
//  the first. Leaving the trail is told **once per departure**: a hiker off
//  the route for an hour has either noticed or chosen it, and a banner every
//  quarter of an hour is the app arguing with somebody who is walking a
//  forest road on purpose.
//
//  What re-arms it is *rejoining*, not time. That is the one event that says
//  the previous departure is over and a new one would be news — and it is why
//  the two thresholds differ: leaving takes
//  ``MovementReminderPolicy/offTrailMeters`` and returning takes the plain
//  follow threshold, so the band between them is neither a new departure nor
//  a return. A walker picking their way back along a faint path sits in that
//  band, and hears nothing, which is right.
//
//  A value type with no clock of its own, for the reason ``MovementWatch`` is
//  one: every decision is a function of what it has been told, so a suite can
//  drive an hour of walking through it without waiting for one.
//

import Foundation

/// One followed trail's relationship to its own route.
nonisolated struct OffTrailWatch: Equatable {
    /// When the current departure began, or `nil` while on the route.
    ///
    /// The *first* fix past the threshold rather than the most recent, which
    /// is what makes the dwell a dwell: a hiker who has been 200 m off for
    /// three minutes has been off for three minutes, however many fixes
    /// arrived in between.
    private var departedAt: Date?
    /// Whether this departure has already been reported. Cleared by
    /// rejoining and by nothing else — see this file's header.
    private var hasReported = false

    /// Records one matched fix, and answers whether the hiker should be told.
    ///
    /// - Parameter offRouteMeters: how far the fix was from the line. `nil`
    ///   for a fix that could not be matched at all, which is **not** evidence
    ///   of being off the route — it is absence of evidence, and the two are
    ///   the difference between a hiker on a path the app cannot see and a
    ///   hiker who has left it. An unmatched fix leaves the watch exactly as
    ///   it was.
    mutating func observed(offRouteMeters: Double?, at date: Date) -> Bool {
        guard let offRouteMeters, offRouteMeters.isFinite else { return false }

        if offRouteMeters <= MovementReminderPolicy.onTrailAgainMeters {
            // Back on the line. This is the only thing that re-arms the
            // reminder, so a second wrong turn later in the walk is news
            // again.
            departedAt = nil
            hasReported = false
            return false
        }

        guard offRouteMeters > MovementReminderPolicy.offTrailMeters else {
            // In the band between the two thresholds: not far enough to be a
            // departure, not close enough to be a return. Whatever the watch
            // was, it stays.
            return false
        }

        guard let start = departedAt else {
            // The first fix past the threshold starts the clock and says
            // nothing. A single bad fix is as likely as a wrong turn.
            departedAt = date
            return false
        }
        guard !hasReported else { return false }
        guard date.timeIntervalSince(start) >= MovementReminderPolicy.offTrailDwell else {
            return false
        }
        hasReported = true
        return true
    }

    /// Forgets everything, which is what ending or un-following a walk does.
    ///
    /// Distinct from rejoining only in that there is nothing left to rejoin;
    /// both leave a watch that would report a fresh departure.
    mutating func reset() {
        departedAt = nil
        hasReported = false
    }

    /// Whether a departure is currently being reported about, for the caller
    /// that has to decide whether a standing banner is still true.
    var isOffTrail: Bool { departedAt != nil }
}
