//
//  TrailWalkSession+TimeLeft.swift
//  OpenHikes
//
//  How long the walk under way has left — see ``WalkTimeLeft`` for the
//  estimate itself. Split from the session for length, and because it is a
//  question asked *of* the walk rather than a step in running it.
//

import Foundation

extension TrailWalkSession {
    /// Seconds to the end of the walked trail at `now`, or `nil` with no walk,
    /// no route to measure against, or nothing honest to say.
    ///
    /// The distance is the walk's own figure — what the route has not yet
    /// had covered, which is what the readout beside it says is left — and
    /// the climb is the line's from where the hiker last matched to its end.
    /// Not observable, like ``activeSeconds()``: the leaves that draw it are
    /// already redrawn by every matched fix.
    func secondsLeft(at now: Date) -> TimeInterval? {
        guard let record, let walkedProfile,
              let position = record.lastFollowedDistanceMeters else { return nil }
        return WalkTimeLeft.seconds(
            profile: walkedProfile,
            position: position,
            remainingMeters: max(0, record.routeDistanceMeters - record.coverage.coveredMeters),
            covered: record.coverage.ranges,
            activeSeconds: record.activeSeconds(at: now)
        )
    }

    /// Tells the reminders when this walk now looks like ending, against
    /// when the light goes — see ``DuskWatch``. Per matched fix while
    /// following, which is as often as the estimate can change.
    func estimateFinish(at now: Date) {
        guard let reminders, let left = secondsLeft(at: now) else { return }
        reminders.walkFinishEstimated(
            finishAt: now.addingTimeInterval(left),
            civilDusk: daylight()?.civilDusk,
            trailTitle: walkedHikeTitle,
            at: now
        )
    }
}
