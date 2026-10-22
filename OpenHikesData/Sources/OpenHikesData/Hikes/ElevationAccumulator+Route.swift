//
//  ElevationAccumulator+Route.swift
//  OpenHikes
//
//  Counting a route's climb the way the route says it was walked: a pause ends
//  the run.
//

import OpenHikesShared

nonisolated public extension ElevationAccumulator {
    /// Feeds one route point's height in, closing the run in progress first
    /// when the point is the first one after a pause.
    ///
    /// Whatever carried the receiver while the recording was paused — a lift,
    /// a car, a night in a hut — the rise from the last height before it to
    /// the first after it is not ground anyone walked. The resumed height is
    /// still a reading, so it counts toward the extremes and starts the next
    /// run; only the step across the pause is left out. The watch ends its run
    /// there too, and every climb the phone counts goes through here so the
    /// two agree on the same walk.
    ///
    /// A boundary on the first point closes nothing, since there is no run for
    /// it to close.
    mutating func record(_ point: RouteCoordinate) {
        if point.isPauseBoundary { endRun() }
        record(point.elevation)
    }
}
