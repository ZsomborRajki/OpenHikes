//
//  RouteSegments.swift
//  OpenHikesData
//
//  The segments a hike's pauses cut it into, each with its own figures, and
//  how long each stop between them was (#1470).
//
//  A segment is a walked run. A pause, by hand or by Auto-Pause, and the
//  break between two GPX `<trkseg>`s all leave a ``RouteBoundary`` on the
//  route, and `[RouteCoordinate].trailRuns` already cuts a line there for the
//  map, the export and Health. So a segment needs no stored field of its own:
//  it is read off the route a hike already has, and a hike paused before
//  segments were shown has them too.
//
//  A lone fix, with a pause on both sides of it, is no segment: nothing was
//  walked to or from it. The stop it stands in runs from the segment before
//  it to the segment after.
//

import Foundation
import OpenHikesShared

/// One walked run of a route, and the stop that followed it.
nonisolated public struct RouteSegment: Sendable, Equatable {
    public var distanceMeters: Double
    /// The time between the segment's first fix and its last, or `nil` for a
    /// route with no clock there. The clock *Avg Speed* divides by: a pause
    /// is outside it, and a rest taken without one is inside.
    public var seconds: TimeInterval?
    /// What the segment climbed, or `nil` until two of its points carry a
    /// height.
    public var elevationGainMeters: Double?
    /// How long the hiker was stopped after this segment, before the next one
    /// began. `nil` after the last segment, and where either end has no time.
    public var stopSeconds: TimeInterval?
    /// The share of ``distanceMeters`` between the segment's first and last
    /// stamped point, the only stretch ``seconds`` is a clock for, as
    /// `HikeRouteStatistics` cuts a whole hike's: ten kilometres with a clock
    /// on the last two would otherwise read as a runner's speed.
    public var timedDistanceFraction: Double

    public init(
        distanceMeters: Double,
        seconds: TimeInterval? = nil,
        elevationGainMeters: Double? = nil,
        stopSeconds: TimeInterval? = nil,
        timedDistanceFraction: Double = 1
    ) {
        self.distanceMeters = distanceMeters
        self.seconds = seconds
        self.elevationGainMeters = elevationGainMeters
        self.stopSeconds = stopSeconds
        self.timedDistanceFraction = timedDistanceFraction
    }

    /// The timed stretch of the segment over ``seconds``, or `nil` where there
    /// is no time to divide by.
    public var averageSpeedMetersPerSecond: Double? {
        guard let seconds, seconds > 0 else { return nil }
        return distanceMeters * timedDistanceFraction / seconds
    }
}

nonisolated public enum RouteSegments {
    /// The most segments a hike is shown as. A file from a device that starts
    /// a `<trkseg>` at every lost signal has hundreds, which are its own
    /// bookkeeping and not a walk's stops, and such a route gives none.
    public static let maximumCount = 30

    /// Cuts a route into its segments as it is walked, a point at a time, so
    /// the hike detail's one pass over a route can feed it — as it feeds
    /// ``HikeRouteStatistics/Builder``.
    ///
    /// A value, so a recording can read what it has so far without ending it
    /// (`RecordingSegmentLedger`).
    public struct Builder: Sendable, Equatable {
        private struct Run: Sendable, Equatable {
            var meters = 0.0
            var pointCount = 1
            var firstTimestamp: Date?
            var lastTimestamp: Date?
            var elevation = ElevationAccumulator()
            /// Metres between the first and the last stamped point so far.
            var timedMeters = 0.0
            /// Metres since the last stamped point, held until a later stamp
            /// claims them, as `HikeRouteStatistics` holds them.
            var pendingMeters = 0.0
        }

        private var segments: [RouteSegment] = []
        private var run: Run?
        /// When the last segment kept ended, for the stop after it.
        private var previousEnd: Date?

        public init() {
            // Everything starts empty; see the stored defaults above.
        }

        /// - Parameter segmentMeters: the distance from the point before, as
        ///   ``RouteCoordinate/legMeters(from:)`` gives it. A paused leg has
        ///   none, and is not read here either way.
        public mutating func consume(_ point: RouteCoordinate, segmentMeters: Double) {
            if point.isPauseBoundary { closeRun() }
            guard var open = run else {
                var opened = Run(firstTimestamp: point.timestamp, lastTimestamp: point.timestamp)
                opened.elevation.record(point.elevation)
                run = opened
                return
            }
            open.meters += segmentMeters
            open.pointCount += 1
            if open.firstTimestamp != nil { open.pendingMeters += segmentMeters }
            if point.timestamp != nil {
                open.timedMeters += open.pendingMeters
                open.pendingMeters = 0
            }
            open.firstTimestamp = open.firstTimestamp ?? point.timestamp
            open.lastTimestamp = point.timestamp ?? open.lastTimestamp
            open.elevation.record(point.elevation)
            run = open
        }

        /// The route's segments, or none for a route that is one piece or
        /// more pieces than ``RouteSegments/maximumCount``.
        ///
        /// - Parameter distanceMeters: the hike's own distance. A recording's
        ///   is shorter than its line, by the wander its stops took back, and
        ///   the segments are scaled to add up to it: they are the one
        ///   distance cut into pieces, and a hiker who found the pieces
        ///   adding up to more would be right to believe neither.
        public consuming func finish(distanceMeters: Double) -> [RouteSegment] {
            closeRun()
            guard segments.count > 1, segments.count <= RouteSegments.maximumCount else { return [] }
            let walked = segments.reduce(0) { $0 + $1.distanceMeters }
            guard walked > 0, distanceMeters.isFinite, distanceMeters > 0 else { return segments }
            let scale = distanceMeters / walked
            return segments.map { segment in
                var scaled = segment
                scaled.distanceMeters *= scale
                return scaled
            }
        }

        private mutating func closeRun() {
            defer { run = nil }
            // A piece of one point is a lone fix: no leg was walked there.
            guard let closed = run, closed.pointCount > 1 else { return }
            if let previousEnd, let began = closed.firstTimestamp, began > previousEnd, !segments.isEmpty {
                segments[segments.count - 1].stopSeconds = began.timeIntervalSince(previousEnd)
            }
            var seconds: TimeInterval?
            if let first = closed.firstTimestamp, let last = closed.lastTimestamp, last > first {
                seconds = last.timeIntervalSince(first)
            }
            segments.append(
                RouteSegment(
                    distanceMeters: closed.meters,
                    seconds: seconds,
                    elevationGainMeters: closed.elevation.hasChange ? closed.elevation.gainMeters : nil,
                    timedDistanceFraction: closed.meters > 0 ? min(closed.timedMeters / closed.meters, 1) : 1
                )
            )
            previousEnd = closed.lastTimestamp
        }
    }

    /// The segments of `route`, walked here: for a reader with no other walk
    /// of the route to ride.
    public static func segments(of route: [RouteCoordinate], distanceMeters: Double) -> [RouteSegment] {
        var builder = Builder()
        var previous: RouteCoordinate?
        for point in route {
            builder.consume(point, segmentMeters: previous.map(point.legMeters(from:)) ?? 0)
            previous = point
        }
        return builder.finish(distanceMeters: distanceMeters)
    }
}
