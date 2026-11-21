//
//  WalkRecordingSeed.swift
//  OpenHikes
//
//  A walk along a trail, as the points a recording can begin with.
//
//  A walk keeps no fixes. It keeps which stretches of the trail its matches
//  covered and which way each was walked, when it began, how long it was
//  active and when it was last on the route — see ``TrailWalkCoverage``. So
//  what a recording is handed is the trail's own line along those stretches,
//  clocked from those figures. That is the same exchange the map matcher
//  makes for a recording when it moves fixes onto a mapped path: where the
//  hiker was is taken from the line they were following, within the distance
//  a match allows.
//
//  ## What is carried
//
//  - **The ground covered, and nothing between.** Each stretch becomes its
//    own run of points, and a run the walk did not reach from the one before
//    it opens with ``RecordingPointFlags/resumed``, which is what a recording
//    writes at its own pauses: no distance and no trail across it (see
//    `RouteBoundary`). A stretch that starts where the last one ended is a
//    turn, and stays one line.
//  - **The walk's active time, on the runs.** The walk's clock from its start
//    to its last match on the route is shared out over the runs by length, so
//    the recording's average speed is the walk's. Time the walk was paused
//    for sits in the breaks, or — a pause that left no break — as a wait at
//    the first point before setting off, so that the first point is stamped
//    with the walk's start and the last with its last match, each to the
//    instant. The library's totals leave a walk out for as long as a
//    recording's clock covers it (`LibraryTotals`), and the walk that was
//    handed over is in its trail's History too.
//  - **The trail's heights**, read off the profile between its plotted
//    samples, where it has any.
//  - **The covered length, in full.** Every point is marked
//    ``RecordingPointFlags/carried``, so a recording counts the line as
//    ground walked, live and at the save, however tightly it bends: the
//    walk's coverage already established it, and the rule that hands back a
//    standing hiker's GPS wander has nothing to weigh.
//
//  ## What is not known
//
//  The stretches say which way each was walked and not when, so the order is
//  taken to be the simple one: the stretches walked the way the walk is going
//  now came last. A walk that went back and forth more than once covered the
//  same ground and the same length in another order.
//
//  Nothing is carried for the ground between the trail and where the hiker
//  stands when the recording begins. The recording's first fix joins the last
//  carried point as any fix joins the one before it, and the save measures
//  that leg as it measures every stretch a recording crossed without a fix.
//

import Algorithms
import CoreLocation
import Foundation
import OpenHikesData

nonisolated extension RecordingSeed {
    /// How good a fix a carried point says it was.
    ///
    /// The line's own figure rather than a receiver's: a walk's matches lay
    /// within ``RouteProfile/followMatchThresholdMeters`` of the trail, but
    /// the point is *on* it, and a point that claimed a match's slack would
    /// have the save's matcher look for it on every path within that
    /// distance. An ordinary fix under open sky is what the trail's line is
    /// worth to it.
    static let carriedAccuracyMeters = 10.0

    /// The longest leg between two carried points, and the longest time.
    ///
    /// Half of what the matcher calls a sparse leg
    /// (``TrailMatcher/sparseDisplacement``, ``TrailMatcher/sparseInterval``).
    /// A drawn trail can run straight for a kilometre between two points, and
    /// a leg that long would be routed as one the recording has no evidence
    /// across, with a section to check asking which way the hiker went along
    /// a trail they were following.
    static let maximumLegMeters = TrailMatcher.sparseDisplacement * sparseLegShare
    static let maximumLegSeconds = TrailMatcher.sparseInterval * sparseLegShare
    private static let sparseLegShare = 0.5

    /// The slowest pace the carried points are clocked at: half as fast
    /// again as the rate below which a recording's moving clock calls a
    /// hiker stopped (``MovingTimeAccumulator/stillnessRate``).
    ///
    /// A walk's active clock runs on while its hiker is off the route, so it
    /// can be far longer than the covered ground took. Shared out over that
    /// ground it would read as a hiker standing still, in the recording's
    /// moving time and its average speed, on ground they walked. The time
    /// past this pace was spent somewhere the coverage does not show, and
    /// goes where a pause's does.
    ///
    /// Clear of that rate rather than at it. The moving clock weighs the net
    /// displacement across half a minute or more, which falls short of the
    /// distance along any line that bends, and a saved route keeps no mark
    /// that its ground was carried: clocked at the rate itself, nearly all of
    /// the carried time read as stopped. The distance does not hang on this:
    /// carried ground counts in full at any pace (``RecordingPointFlags/carried``).
    static let slowestWalkingSpeed = MovingTimeAccumulator.stillnessRate * clearOfStillness
    private static let clearOfStillness = 1.5

    /// The least time a break takes, so that the point after it is later than
    /// the one before: the save drops a point stamped like the last.
    static let minimumBreakSeconds: TimeInterval = 1

    /// How far apart along the route two stretches may be and still meet.
    private static let joinToleranceMeters = 1.0

    /// What `walk` covered of the line `profile` indexes, as the points a
    /// recording begins with, or `nil` for a walk that covered nothing.
    ///
    /// `profile` has to be the line the walk is along — see
    /// ``TrailWalkRecord/routeRevision`` — because every distance the walk
    /// keeps is a distance along that line.
    static func carrying(_ walk: TrailWalkRecord, along profile: RouteProfile) -> Self? {
        let covered = runs(of: walk.coverage, along: profile)
        let meters = covered.reduce(0) { total, run in total + run.meters }
        guard meters > 0, let pacing = Pacing(of: walk, over: meters, breaks: covered.count - 1) else { return nil }

        var carried: [RecordingPoint] = []
        var time = walk.startedAt
        if pacing.wait > 0, let first = covered.first?.vertices.first {
            carried.append(point(first, at: time, opensRun: false))
            time += pacing.wait
        }
        for (index, run) in covered.enumerated() {
            if index > 0 { time += pacing.perBreak }
            let seconds = pacing.moving * run.meters / meters
            carried.append(contentsOf: points(along: run, from: time, taking: seconds, opensRun: !carried.isEmpty))
            time += seconds
        }
        // The sums above end a few ulps off the walk's last match, and the
        // clock these points give a recording has to reach it exactly: a
        // walk that a recording's clock covers all but an instant of still
        // counts as an outing of its own (`LibraryTotals`).
        if let last = carried.popLast() {
            carried.append(last.stamped(walk.lastActivityAt))
        }
        return Self(startedAt: walk.startedAt, points: carried)
    }
}

nonisolated private extension RecordingPoint {
    /// This point, taken at `date`.
    func stamped(_ date: Date) -> Self {
        Self(
            latitude: latitude,
            longitude: longitude,
            timestamp: date,
            horizontalAccuracy: horizontalAccuracy,
            elevation: elevation,
            course: course,
            speed: speed,
            flags: flags
        )
    }
}

// MARK: - The clock

/// How a walk's time, from its start to its last match on the route, is
/// shared out over what it covered.
nonisolated private struct Pacing {
    /// Seconds on the runs themselves.
    let moving: TimeInterval
    /// Seconds between one run and the next.
    let perBreak: TimeInterval
    /// Seconds at the first point before setting off: the time not spent
    /// moving, for a walk with no break to put it in.
    let wait: TimeInterval

    private static let half = 0.5

    /// `nil` for a walk with no time between its start and its last match.
    init?(of walk: TrailWalkRecord, over meters: Double, breaks: Int) {
        let endedAt = walk.lastActivityAt
        let elapsed = endedAt.timeIntervalSince(walk.startedAt)
        guard elapsed > 0 else { return nil }
        let active = min(walk.activeSeconds(at: endedAt), elapsed)
        let walking = min(active > 0 ? active : elapsed, meters / RecordingSeed.slowestWalkingSpeed)
        let idle = elapsed - walking
        guard breaks > 0 else {
            wait = idle >= RecordingSeed.minimumBreakSeconds ? idle : 0
            moving = elapsed - wait
            perBreak = 0
            return
        }
        wait = 0
        let each = max(idle / Double(breaks), RecordingSeed.minimumBreakSeconds)
        if elapsed > each * Double(breaks) {
            perBreak = each
            moving = elapsed - each * Double(breaks)
        } else {
            // A clock too short for its breaks: half to them, half to the
            // runs, so every point is still later than the one before.
            perBreak = elapsed * Self.half / Double(breaks)
            moving = elapsed * Self.half
        }
    }
}

// MARK: - The line

/// One point of a carried line.
nonisolated private struct Vertex {
    let coordinate: CLLocationCoordinate2D
    let elevation: Double?
}

/// One unbroken line the walk covered, in the order it was walked.
nonisolated private struct Run {
    var vertices: [Vertex]

    var meters: Double {
        RouteGeometry.lengthMeters(of: vertices.map(\.coordinate))
    }
}

/// The profile's plotted heights, read between the samples.
nonisolated private struct Heights {
    let samples: [ElevationSample]

    func elevation(at distance: Double) -> Double? {
        guard let first = samples.first, let last = samples.last else { return nil }
        if distance <= first.distanceMeters { return first.elevation }
        if distance >= last.distanceMeters { return last.elevation }
        let upper = samples.partitioningIndex { $0.distanceMeters >= distance }
        let below = samples[upper - 1]
        let above = samples[upper]
        let span = above.distanceMeters - below.distanceMeters
        guard span > 0 else { return above.elevation }
        return below.elevation + (above.elevation - below.elevation) * (distance - below.distanceMeters) / span
    }
}

nonisolated private extension RecordingSeed {
    /// The walk's stretches, with which way each was walked, in the order
    /// they are taken to have been walked: the way the walk is going now
    /// last. See *What is not known* in the file header.
    static func stretches(of coverage: TrailWalkCoverage) -> [(range: ClosedRange<Double>, back: Bool)] {
        let out = coverage.walkedTowardsEnd.map { (range: $0, back: false) }
        // Walked back, so the furthest along the route came first.
        let back = coverage.walkedTowardsStart.reversed().map { (range: $0, back: true) }
        return coverage.direction == .towardsEnd ? back + out : out + back
    }

    /// The stretches as lines, each joined to the one before it where the
    /// walk reached it from there, and cut where the route itself is: a
    /// trail's own pause is no more walked than a walk's.
    static func runs(of coverage: TrailWalkCoverage, along profile: RouteProfile) -> [Run] {
        let heights = Heights(samples: profile.samples)
        var covered: [Run] = []
        var reached: Double?
        for stretch in stretches(of: coverage) {
            var pieces = lines(covering: stretch.range, along: profile, heights: heights)
            if stretch.back { pieces = pieces.reversed().map { $0.reversed() } }
            guard !pieces.isEmpty else { continue }
            let start = stretch.back ? stretch.range.upperBound : stretch.range.lowerBound
            if let reached, abs(reached - start) <= joinToleranceMeters, !covered.isEmpty {
                // The point the two share is the last one's end already.
                covered[covered.count - 1].vertices.append(contentsOf: pieces.removeFirst().dropFirst())
            }
            covered.append(contentsOf: pieces.map { Run(vertices: $0) })
            reached = stretch.back ? stretch.range.lowerBound : stretch.range.upperBound
        }
        return covered.filter { $0.meters > 0 }
    }

    /// The route between two distances, the way its distances run, with the
    /// height at each point.
    static func lines(
        covering range: ClosedRange<Double>,
        along profile: RouteProfile,
        heights: Heights
    ) -> [[Vertex]] {
        // A paused leg has no length on the profile's axis, so the pieces'
        // own lengths, added up from the range's start, are distances on it.
        var reached = range.lowerBound
        return profile.stretches(covering: range).map { line in
            let distances = line.adjacentPairs().reductions(reached) { traveled, leg in
                traveled + RouteGeometry.distanceMeters(from: leg.0, to: leg.1)
            }
            reached = distances.last ?? reached
            return zip(line, distances).map { coordinate, distance in
                Vertex(coordinate: coordinate, elevation: heights.elevation(at: distance))
            }
        }
    }

    /// `run` as points from `start`, walked evenly in `seconds`, with points
    /// added along any leg too long for one — see ``maximumLegMeters``.
    static func points(
        along run: Run,
        from start: Date,
        taking seconds: TimeInterval,
        opensRun: Bool
    ) -> [RecordingPoint] {
        guard let first = run.vertices.first else { return [] }
        let meters = run.meters
        var carried = [point(first, at: start, opensRun: opensRun)]
        var time = start
        for (from, to) in run.vertices.adjacentPairs() {
            let leg = RouteGeometry.distanceMeters(from: from.coordinate, to: to.coordinate)
            guard leg > 0, meters > 0 else { continue }
            let legSeconds = seconds * leg / meters
            let steps = max(1, Int(max(leg / maximumLegMeters, legSeconds / maximumLegSeconds).rounded(.up)))
            for step in 1...steps {
                let fraction = Double(step) / Double(steps)
                carried.append(
                    point(between: from, and: to, at: fraction, on: time.addingTimeInterval(legSeconds * fraction))
                )
            }
            time += legSeconds
        }
        return carried
    }

    static func point(between from: Vertex, and to: Vertex, at fraction: Double, on date: Date) -> RecordingPoint {
        guard fraction < 1 else { return point(to, at: date, opensRun: false) }
        let elevation: Double? = if let low = from.elevation, let high = to.elevation {
            low + (high - low) * fraction
        } else {
            nil
        }
        return point(
            Vertex(
                coordinate: RouteGeometry.interpolate(from: from.coordinate, to: to.coordinate, fraction: fraction),
                elevation: elevation
            ),
            at: date,
            opensRun: false
        )
    }

    static func point(_ vertex: Vertex, at date: Date, opensRun: Bool) -> RecordingPoint {
        RecordingPoint(
            latitude: vertex.coordinate.latitude,
            longitude: vertex.coordinate.longitude,
            timestamp: date,
            horizontalAccuracy: carriedAccuracyMeters,
            elevation: vertex.elevation,
            flags: opensRun ? [.carried, .resumed] : .carried
        )
    }
}
