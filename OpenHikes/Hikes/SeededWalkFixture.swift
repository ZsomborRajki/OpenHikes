//
//  SeededWalkFixture.swift
//  OpenHikes
//
//  A walk along a hike nobody walked, behind `--ui-test-seed-walks=<name>`.
//
//  The History segment and the Walk Summary are about a *finished* walk, and
//  finishing one in the Simulator is a minute of simulated fixes per
//  scenario — too slow for a check that a row reads as one element, or that
//  the summary leads with a percentage. This writes the row directly, through
//  the real store, so what a test reads afterwards is the shipping query, the
//  shipping cascade and the shipping formatting; only the walk is invented.
//
//  Mirrors `SeededPhotoFixture`, and like it is compiled only into `DEBUG`.
//

import Foundation
import SwiftData

#if DEBUG
nonisolated enum SeededWalkFixture {
    /// The names a launch may ask for. Exactly one for now: half the route,
    /// walked yesterday and ended by the walker, which is enough to draw
    /// every element of a row and a summary.
    private static let halfLoop = "HalfLoop"
    private static let halfLoopActiveSeconds: TimeInterval = 45 * 60
    /// Yesterday, comfortably: a day and two hours before the launch.
    private static let halfLoopStartOffset: TimeInterval = -(24 + 2) * 3600
    private static let halfLoopFraction = 0.5

    @MainActor
    static func attach(named name: String, to hike: Hike, in context: ModelContext) {
        guard name == halfLoop, hike.isAttached else { return }
        let routeDistance = hike.distanceMeters
        let covered = routeDistance * halfLoopFraction
        let startedAt = Date(timeIntervalSinceNow: halfLoopStartOffset)
        let walk = HikeWalk(
            hikeID: hike.id,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(halfLoopActiveSeconds),
            activeSeconds: halfLoopActiveSeconds,
            coveredIntervals: [0, covered],
            furthestDistanceMeters: covered,
            routeDistanceMeters: routeDistance,
            endReason: .ended
        )
        context.insert(walk)
        walk.hike = hike
        try? context.save()
    }
}
#endif
