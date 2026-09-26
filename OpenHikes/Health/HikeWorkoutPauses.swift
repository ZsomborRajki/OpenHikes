//
//  HikeWorkoutPauses.swift
//  OpenHikes
//
//  When a finished walk was not walking, in the shape Health wants it.
//
//  ## Why not a shorter workout
//
//  A walk used to be exported as `startedAt` plus its moving time, which kept a
//  paused lunch out of the workout's duration by moving its *end*: a hike that
//  began at 09:00, paused from 10:00 to 11:00 and stopped at 12:00 reached
//  Health ending at 11:00, while the last hour of its route still carried its
//  real timestamps. HealthKit already has the right tool —
//  `HKWorkoutBuilder.elapsedTime(at:)` leaves out every stretch between a
//  pause event and the resume after it — so the workout keeps the wall clock
//  the hiker walked and the pauses say what did not count.
//
//  ## Whose pauses
//
//  The route's, not the journal's. The duration Health should arrive at is the
//  one the hike shows — ``PreparedRecording/recordedSeconds`` on the phone,
//  `WatchWalkAccumulator.activeSeconds` on the watch — and both are the gaps
//  between consecutive points with the leg a ``RouteBoundary`` opens left out.
//  `TrackJournalMetadata.pausedIntervals` is not the whole record of when a
//  recording was not running, for the reason `recordedSeconds` gives, so a
//  workout paused by it would disagree with the hike it came from. The
//  complement of the route's segments is, by construction, the same figure.
//

import Foundation
import OpenHikesData

nonisolated enum HikeWorkoutPauses {
    /// When the workout ends: when the hiker stopped, or the last point if the
    /// route runs past that, so no point of the line falls outside the workout
    /// it belongs to. `nil` — a session recovered with no end written — is the
    /// last point too.
    static func end(
        stoppedAt: Date?,
        startedAt: Date,
        route: [RouteCoordinate]
    ) -> Date {
        let lastPoint = route.last { $0.timestamp != nil }?.timestamp
        return [stoppedAt, lastPoint, startedAt].compactMap(\.self).max() ?? startedAt
    }

    /// The stretches between `start` and `end` the route was not recording:
    /// before its first point, across every ``RouteBoundary/paused`` leg, and
    /// after its last point — which is where stopping while paused shows up.
    ///
    /// Empty for a route with no timestamped point, which is no evidence about
    /// when the walk stood still rather than evidence that it always did.
    static func pauses(
        in route: [RouteCoordinate],
        from start: Date,
        to end: Date
    ) -> [DateInterval] {
        guard end > start else { return [] }
        let segments = activeSegments(of: route)
        guard !segments.isEmpty else { return [] }
        var pauses: [DateInterval] = []
        var cursor = start
        for segment in segments {
            let from = max(segment.start, start)
            let to = min(segment.end, end)
            guard to > from else { continue }
            if from > cursor {
                pauses.append(DateInterval(start: cursor, end: from))
            }
            cursor = max(cursor, to)
        }
        if end > cursor {
            pauses.append(DateInterval(start: cursor, end: end))
        }
        return pauses
    }

    /// Each unbroken run of timestamped points, first to last. A point with no
    /// timestamp says nothing about time and is passed over, the way
    /// `HealthKitWorkoutWriter` leaves it off the workout's route.
    private static func activeSegments(of route: [RouteCoordinate]) -> [DateInterval] {
        var segments: [DateInterval] = []
        var current: DateInterval?
        for point in route {
            guard let timestamp = point.timestamp else { continue }
            if point.boundary == .paused, let finished = current {
                segments.append(finished)
                current = nil
            }
            if let open = current {
                current = DateInterval(start: open.start, end: max(open.end, timestamp))
            } else {
                current = DateInterval(start: timestamp, duration: 0)
            }
        }
        if let current { segments.append(current) }
        return segments
    }
}
