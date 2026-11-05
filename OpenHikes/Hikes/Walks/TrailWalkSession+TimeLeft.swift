//
//  TrailWalkSession+TimeLeft.swift
//  OpenHikes
//
//  How far and how long the walk under way has left — see ``WalkTimeLeft``
//  for the estimate itself. Split from the session for length, and because it
//  is a question asked *of* the walk rather than a step in running it.
//

import CoreLocation
import Foundation
import OpenHikesData

extension TrailWalkSession {
    /// Seconds to the end of the walked trail at `now`, or `nil` with no walk,
    /// no route to measure against, or nothing honest to say.
    ///
    /// The distance and the climb are both the line's, from where the hiker
    /// last matched to the end the walk is going for: ``metersLeft``, the
    /// distance the readout beside it states.
    /// Not observable, like ``activeSeconds()``: the leaves that draw it are
    /// already redrawn by every matched fix, through ``metersLeft``.
    func secondsLeft(at now: Date) -> TimeInterval? {
        guard let record, let walkedProfile,
              let position = record.lastFollowedDistanceMeters else { return nil }
        return WalkTimeLeft.seconds(
            profile: walkedProfile,
            position: position,
            coverage: record.coverage,
            activeSeconds: record.activeSeconds(at: now)
        )
    }

    /// How far `walk` has left: from where the hiker last matched to the end
    /// the walk is going for — see ``WalkTimeLeft/metersAhead(position:coverage:routeMeters:)``.
    /// The whole route before a first match, when nothing says where on it
    /// the hiker is.
    ///
    /// Not the ground the walk has yet to cover, which is the percentage
    /// hiked: a hiker who turned back has the way back ahead of them, and
    /// none of the ground beyond the turn (#1304).
    static func metersLeft(of walk: TrailWalkRecord) -> Double {
        guard let position = walk.lastFollowedDistanceMeters else { return walk.routeDistanceMeters }
        return WalkTimeLeft.metersAhead(
            position: position,
            coverage: walk.coverage,
            routeMeters: walk.routeDistanceMeters
        )
    }

    /// Tells the reminders when this walk now looks like ending, against
    /// when the light goes — see ``DuskWatch``. Per matched fix while
    /// following, which is as often as the estimate can change.
    func estimateFinish(at now: Date) {
        guard let reminders, let hikeID = walkedHikeID,
              let left = secondsLeft(at: now) else { return }
        let position = record?.lastFollowedDistanceMeters.flatMap { walkedProfile?.coordinate(atDistance: $0) }
        reminders.walkFinishEstimated(
            finishAt: now.addingTimeInterval(left),
            civilDusk: daylight(hikeID, position)?.civilDusk,
            trailTitle: walkedHikeTitle,
            at: now
        )
    }
}
