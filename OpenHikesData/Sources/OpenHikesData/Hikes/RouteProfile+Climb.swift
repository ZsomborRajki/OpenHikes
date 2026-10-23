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
//  what the whole route's count credited between its first height and its
//  last, so:
//  - the whole route agrees with ``RouteProfile/elevation`` to the metre;
//  - stretches that meet at a height add up to the stretch they make, which
//    is what ``RouteProfile/climb(over:)`` relies on. A cut that falls
//    between two heights leaves the step it falls on to neither side, as a
//    count over each stretch's own heights always did;
//  - a pause needs no lookup, because the count already ended its run there.
//    Its figures do not move across one either, so a stretch that begins or
//    ends at a join, where the fix before a pause and the fix after it stand
//    at one distance, reads the same whichever of the two it lands on.
//
//  What it gives up is the deadband's judgment at a stretch's start. A count
//  begun there would judge the first few metres for itself; this one carries
//  on the route's run. A stretch that starts within the deadband of a run's
//  peak (or trough) starts, as far as the count goes, at that peak: a turn
//  from it is credited from the peak once the route confirms it, even when
//  the part inside the stretch is smaller than the deadband, and a climb on
//  past it counts only above it. The two readings differ by less than twice
//  ``ElevationAccumulator/reversalThresholdMeters``, and only at that end —
//  and the route's verdict, which saw the ground either side, is the better
//  one.
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
        // The count never goes down — a run's provisional figure is committed
        // as the very sum it reported — so neither difference is below zero.
        // The floor only guards that.
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

    /// What a walk climbed and dropped over the stretches it covered, each
    /// the way it was walked: ``climb(over:)`` of those walked towards the
    /// route's end, and of those walked back towards its start turned round,
    /// since a descent walked uphill is an ascent. A stretch walked there and
    /// back is climbed both ways. `nil` when no stretch had two heights to
    /// compare.
    func climb(walking coverage: TrailWalkCoverage) -> (gainMeters: Double, lossMeters: Double)? {
        let onward = climb(over: coverage.walkedTowardsEnd)
        let back = climb(over: coverage.walkedTowardsStart)
        guard onward != nil || back != nil else { return nil }
        return (
            (onward?.gainMeters ?? 0) + (back?.lossMeters ?? 0),
            (onward?.lossMeters ?? 0) + (back?.gainMeters ?? 0)
        )
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
