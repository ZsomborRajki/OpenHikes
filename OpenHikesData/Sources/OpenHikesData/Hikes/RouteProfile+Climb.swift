//
//  RouteProfile+Climb.swift
//  OpenHikes
//
//  What one stretch of a route climbs and drops — the question a walk asks
//  about the part still ahead of it, and about the part it has already
//  covered.
//
//  ## Every height, not the chart's
//
//  The answer is read from every height the route has, never from
//  ``RouteProfile/samples``. Those are thinned to the chart's budget, keeping
//  each bucket's lowest and highest point: the right picture, and the wrong
//  sum, because every rise between two plotted points is gone. On a rolling
//  route past the budget a walk's estimates and its share card read a
//  fraction of the climb the hike's own statistics report (#963).
//
//  ## Read off the whole route's count
//
//  The build walks the route once through ``ElevationAccumulator`` for the
//  hike's totals, and notes, at each height, what that count had reached.
//  A stretch's climb is the difference between its last height's mark and
//  its first's: two binary searches, whatever the stretch's length. Walks ask
//  per matched fix, more than once — the time left, the widget's payload and
//  the reminders each ask for the climb ahead and the climb covered — and a
//  fresh pass over a twenty-thousand-point import's heights each time would
//  be paid on the main thread every second.
//
//  It is also the more consistent answer. A stretch is credited with exactly
//  what the whole route's count credited to the ground inside it, so:
//  - the whole route agrees with ``RouteProfile/elevation`` to the metre;
//  - stretches that meet add up to the stretch they make, which is what
//    ``RouteProfile/climb(over:)`` relies on;
//  - a pause needs no lookup, because the count already ended its run there.
//
//  What it gives up is the deadband's judgment at a stretch's own ends. One
//  that begins on a wobble inside a run takes the route's verdict on it
//  rather than counting the wobble afresh, so the two readings differ by
//  less than ``ElevationAccumulator/reversalThresholdMeters`` an end — and
//  the route's verdict, which saw the ground either side, is the better one.
//

import Algorithms
import Foundation
import OpenHikesShared

nonisolated public extension RouteProfile {
    /// The ascent and descent between two distances along the route, walked
    /// from the lower towards the higher, or `nil` when fewer than two heights
    /// fall inside it.
    ///
    /// Over every height inside the stretch, through the same count as the
    /// route's own totals — see the file header. A pause ends the run, so a
    /// stretch spanning one leaves out the rise across it, however far the
    /// hiker was carried. O(log n), so cheap enough to ask per matched fix.
    func climb(from start: Double, to end: Double) -> (gainMeters: Double, lossMeters: Double)? {
        let lower = min(start, end)
        let upper = max(start, end)
        let first = climbMarks.partitioningIndex { $0.distanceMeters >= lower }
        let past = climbMarks[first...].partitioningIndex { $0.distanceMeters > upper }
        guard past - first >= 2 else { return nil }
        let entry = climbMarks[first]
        let exit = climbMarks[past - 1]
        // The count only ever grows, so this is never below zero but by a
        // rounding: a run's provisional figure and the committed one that
        // replaces it are the same sum, added up in a different order.
        return (max(0, exit.gainMeters - entry.gainMeters), max(0, exit.lossMeters - entry.lossMeters))
    }

    /// What `stretches` climb and drop between them: each one's
    /// ``climb(from:to:)``, added up — the part of a route a walk has covered
    /// is rarely one stretch. `nil` when none of them had two heights to
    /// compare.
    func climb(over stretches: [ClosedRange<Double>]) -> (gainMeters: Double, lossMeters: Double)? {
        let climbs = stretches.compactMap { climb(from: $0.lowerBound, to: $0.upperBound) }
        guard !climbs.isEmpty else { return nil }
        return climbs.reduce((gainMeters: 0, lossMeters: 0)) { total, climb in
            (total.gainMeters + climb.gainMeters, total.lossMeters + climb.lossMeters)
        }
    }
}

nonisolated extension RouteProfile {
    /// One height on the route, and how far the route's own climb count had
    /// got on reaching it — run in progress included, as
    /// ``ElevationAccumulator/gainMeters`` reports it. Twenty-four bytes a
    /// height, built in the pass that builds everything else.
    struct ClimbMark: Sendable {
        let distanceMeters: Double
        let gainMeters: Double
        let lossMeters: Double

        init(distanceMeters: Double, accumulated: ElevationAccumulator) {
            self.distanceMeters = distanceMeters
            gainMeters = accumulated.gainMeters
            lossMeters = accumulated.lossMeters
        }
    }
}
