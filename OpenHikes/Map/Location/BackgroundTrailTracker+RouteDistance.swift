//
//  BackgroundTrailTracker+RouteDistance.swift
//  OpenHikes
//
//  Telling the walk how far off the line a fix fell.
//
//  Its own file, alongside `+LiveActivity`, `+Snapshot` and `+SnapshotWriter`,
//  because `BackgroundTrailTracker.swift` is at its `file_length` limit and
//  this is the piece that can leave without opening anything up: `walkSession`
//  is the only thing it touches, and that was already internal. It was a
//  `private extension` in that file only because it happened to be written
//  there.
//

import Foundation

extension BackgroundTrailTracker {
    /// Hands one fix's distance from the route to the walk session, which is
    /// where the off-trail reminder's state machine lives.
    ///
    /// Called from **both** feeds and on every fix, matched or not: a fix
    /// back on the line is what re-arms the reminder, so reporting only the
    /// misses would tell a hiker once and never again. `nil` means the fix
    /// could not be matched at all, which is absence of evidence rather than
    /// evidence of absence — see ``OffTrailWatch``.
    func reportRouteDistance(
        hikeID: UUID,
        offRouteMeters: Double?,
        at date: Date
    ) {
        walkSession?.recordRouteDistance(
            hikeID: hikeID,
            offRouteMeters: offRouteMeters,
            at: date
        )
    }
}
