//
//  LibraryLineOutline.swift
//  OpenHikes
//
//  A hike's line thinned until the map can afford every hike in the library
//  at once.
//
//  The map draws each finished hike faded beneath the selected one (see
//  `LibraryLines.swift`). A day's recording is twenty thousand points, and a
//  library is as long as a hiker's walking life, so what the map keeps for a
//  hike that is not selected is this: at most ``maximumPoints`` points, cut
//  where the hike was paused. The selected hike is still drawn from its whole
//  line, by its own renderer.
//
//  ## How it is thinned
//
//  Two passes, both in metres on the run's own tangent plane
//  (``RouteGeometry/localOffset(from:to:)``), so the search below is
//  arithmetic rather than trigonometry per point:
//
//  1. A point closer than ``minimumSpacingMeters`` to the last one kept is
//     dropped. That is most of a walking recording, a fix a second being a
//     metre or two, and none of its shape: it is under the width of the line
//     at every zoom a valley fits on screen at.
//  2. What is left is cut to the budget by Ramer–Douglas–Peucker run the other
//     way round. ``CommunityRouteOutline`` doubles a tolerance until its
//     answer fits, which is a whole pass per doubling and fine once per
//     upload; a library is read at every launch. Here the span whose farthest
//     point is farthest from it is split next, until the budget is spent or
//     nothing is farther than ``toleranceFloorMeters``: one pass, the budget
//     met exactly, and the points spent where the shape is, across every run
//     of the hike at once.
//
//  Measured against the segment, not the line through its ends, for the
//  reason ``CommunityRouteOutline`` gives (#964): an out-and-back's turnaround
//  sits on the line through where it starts and stops.
//
//  ## Pauses
//
//  A paused leg is not trail (#962), so the outline is cut where the line is
//  and drawn as runs. A GPX file opens a pause at every `<trkseg>`, and
//  nothing bounds how many a file holds, so only the ``pauseBudget`` longest
//  breaks stay breaks and the rest are folded into the line, as the watch's
//  package folds them (`WatchTrailPackage+Budget.swift`, #1023). That is what
//  keeps ``maximumPoints`` a bound rather than a hope: every run keeps both
//  of its ends.
//

import CoreLocation
import HeapModule
import OpenHikesData
import OpenHikesShared

nonisolated enum LibraryLineOutline {
    /// The most points one hike's outline carries, across all of its runs.
    ///
    /// Enough that a switchbacked climb still reads as switchbacks at the zoom
    /// a valley fits on screen at, and few enough that a library of hundreds
    /// is a few megabytes and a tap measures it in a few milliseconds.
    static let maximumPoints = 256

    /// The most pauses an outline keeps as breaks. Each costs two points of
    /// ``maximumPoints``, so this leaves most of the budget to the shape.
    static let pauseBudget = 32

    /// How close a point may be to the last one kept before it is dropped.
    static let minimumSpacingMeters: Double = 4

    /// How far a point has to be from the line that would replace it to be
    /// worth a point of the budget at all.
    static let toleranceFloorMeters: Double = 2

    /// `route` thinned and cut at its pauses: runs of two points or more, in
    /// order, or none for a route with no line in it.
    static func runs(
        of route: [RouteCoordinate],
        maximumPoints: Int = Self.maximumPoints,
        pauseBudget: Int = Self.pauseBudget
    ) -> [[CLLocationCoordinate2D]] {
        let spaced = keptRuns(of: route, pauseBudget: pauseBudget).compactMap { range in
            let points = spacedOut(route[range])
            return points.count > 1 ? points : nil
        }
        return fitted(spaced, maximumPoints: maximumPoints)
    }

    /// The route's walked runs, with every pause past the ``pauseBudget``
    /// longest folded back into the line.
    ///
    /// Longest by the gap on the ground, ties to the earlier, so the same
    /// route always cuts the same way. A gap nobody can measure is no reason
    /// to keep a break over one that can be.
    static func keptRuns(of route: [RouteCoordinate], pauseBudget: Int) -> [Range<Int>] {
        let runs = route.trailRuns
        guard runs.pausedLegs.count > pauseBudget else { return runs.walkedRuns }
        let gaps = runs.pausedLegs.map { leg in
            let gap = RouteGeometry.distanceMeters(from: route[leg].clCoordinate, to: route[leg + 1].clCoordinate)
            return gap.isFinite ? gap : 0
        }
        let kept = runs.pausedLegs.indices
            .sorted { gaps[$0] != gaps[$1] ? gaps[$0] > gaps[$1] : $0 < $1 }
            .prefix(max(0, pauseBudget))
            // The point each kept pause arrives at, which is what a pause is
            // named by — see ``TrailRuns``.
            .map { runs.pausedLegs[$0] + 1 }
        return TrailRuns(pointCount: route.count, pauseIndices: kept).walkedRuns
    }

    /// The run's valid points, less every one closer than
    /// ``minimumSpacingMeters`` to the point kept before it. The run's last
    /// point is kept whatever, so the line ends where the walk did.
    static func spacedOut(_ points: some Collection<RouteCoordinate>) -> [CLLocationCoordinate2D] {
        let spacing = minimumSpacingMeters * minimumSpacingMeters
        var kept: [CLLocationCoordinate2D] = []
        var dropped: CLLocationCoordinate2D?
        for point in points {
            let coordinate = point.clCoordinate
            guard CLLocationCoordinate2DIsValid(coordinate) else { continue }
            if let last = kept.last {
                let offset = RouteGeometry.localOffset(from: last, to: coordinate)
                guard offset.x * offset.x + offset.y * offset.y >= spacing else {
                    dropped = coordinate
                    continue
                }
            }
            kept.append(coordinate)
            dropped = nil
        }
        if let dropped { kept.append(dropped) }
        return kept
    }

    /// `runs` cut down to `maximumPoints` between them, each keeping its ends.
    static func fitted(_ runs: [[CLLocationCoordinate2D]], maximumPoints: Int) -> [[CLLocationCoordinate2D]] {
        guard runs.reduce(0, { $0 + $1.count }) > maximumPoints else { return runs }
        let planes = runs.map { run in run.map { Plane.Point(RouteGeometry.localOffset(from: run[0], to: $0)) } }
        var keep = runs.map { run in run.indices.map { $0 == 0 || $0 == run.count - 1 } }
        var spent = runs.count * 2
        var spans = Heap<Span>()
        for (run, plane) in planes.enumerated() {
            if let span = Span(run: run, first: 0, last: plane.count - 1, in: plane) { spans.insert(span) }
        }
        while spent < maximumPoints, let span = spans.popMax(), span.error > toleranceFloorMeters {
            keep[span.run][span.farthest] = true
            spent += 1
            let plane = planes[span.run]
            if let left = Span(run: span.run, first: span.first, last: span.farthest, in: plane) {
                spans.insert(left)
            }
            if let right = Span(run: span.run, first: span.farthest, last: span.last, in: plane) {
                spans.insert(right)
            }
        }
        return runs.indices.map { run in
            runs[run].indices.compactMap { keep[run][$0] ? runs[run][$0] : nil }
        }
    }
}

// MARK: - The search

nonisolated private extension LibraryLineOutline {
    /// Metres east and north of a run's first point.
    enum Plane {
        struct Point {
            let east: Double
            let north: Double

            init(_ offset: (x: Double, y: Double)) {
                east = offset.x
                north = offset.y
            }
        }

        /// How far `point` is from the segment between `start` and `end`:
        /// from the nearest point *on* it, clamped to its ends.
        static func distance(of point: Point, from start: Point, to end: Point) -> Double {
            let east = end.east - start.east
            let north = end.north - start.north
            let lengthSquared = east * east + north * north
            let projection = (point.east - start.east) * east + (point.north - start.north) * north
            let along = lengthSquared > 0 ? min(max(projection / lengthSquared, 0), 1) : 0
            return hypot(point.east - (start.east + along * east), point.north - (start.north + along * north))
        }
    }

    /// The points strictly between two kept ones, and the one of them
    /// farthest from the segment that would replace them.
    struct Span: Comparable {
        let error: Double
        let run: Int
        let first: Int
        let last: Int
        let farthest: Int

        /// `nil` for a span with no point between its ends.
        init?(run: Int, first: Int, last: Int, in plane: [Plane.Point]) {
            guard last > first + 1 else { return nil }
            var farthestIndex = first + 1
            var largest = -1.0
            for index in (first + 1)..<last {
                let distance = Plane.distance(of: plane[index], from: plane[first], to: plane[last])
                if distance > largest {
                    largest = distance
                    farthestIndex = index
                }
            }
            error = largest
            self.run = run
            self.first = first
            self.last = last
            farthest = farthestIndex
        }

        /// By error, and among equal errors the earlier span first, so the
        /// same line always thins the same way.
        static func < (lhs: Self, rhs: Self) -> Bool {
            if lhs.error != rhs.error { return lhs.error < rhs.error }
            if lhs.run != rhs.run { return lhs.run > rhs.run }
            return lhs.first > rhs.first
        }
    }
}
