//
//  RouteInference.swift
//  OpenHikes
//
//  Which parts of a saved route were measured and which were reasoned about.
//
//  Also which parts of it the walker chose not to record at all: a pause is
//  neither a measurement nor an inference, and ``RouteBoundary`` is what the
//  map and the elevation profile read to say so.
//
//  A recording that loses its fixes still has to produce a continuous line, so
//  something gets drawn across the stretch nobody observed — a mapped trail
//  ``TrailMatcher`` bridged the gap with, or a straight line where it found
//  none. Both are inferences. These are what let the map draw them as such and
//  the stats say how much of the walk they account for, rather than presenting
//  a guess with the same authority as a measurement.
//

import CoreLocation
import Foundation

nonisolated extension [RouteCoordinate] {
    /// The stretches drawn across ground the recording never observed, as runs
    /// of coordinates ready to hand to `MKPolyline`.
    ///
    /// ``RouteProvenance`` marks the segment *arriving* at a point, so a run of
    /// inferred points beginning at `index` describes a line that starts at
    /// `index - 1` — the last measured position before the recording went
    /// quiet. Including it is what makes the drawn stretch meet the rest of the
    /// route instead of floating a segment away from it.
    var inferredSegments: [[CLLocationCoordinate2D]] {
        guard count > 1 else { return [] }
        var segments: [[CLLocationCoordinate2D]] = []
        var current: [CLLocationCoordinate2D] = []
        for index in 1..<count {
            guard self[index].isInferred else {
                if current.count > 1 { segments.append(current) }
                current = []
                continue
            }
            if current.isEmpty {
                current.append(self[index - 1].clCoordinate)
            }
            current.append(self[index].clCoordinate)
        }
        if current.count > 1 { segments.append(current) }
        return segments
    }

    /// How much of the route's length crosses ground it never observed.
    ///
    /// Measured over the drawn geometry, so it is directly comparable with the
    /// hike's own distance: "3.2 km of these 14.6 km is inferred" is the
    /// sentence it exists to support.
    var inferredDistanceMeters: Double {
        guard count > 1 else { return 0 }
        var total = 0.0
        for index in 1..<count where self[index].isInferred {
            total += RouteGeometry.distanceMeters(
                from: self[index - 1].clCoordinate,
                to: self[index].clCoordinate
            )
        }
        return total
    }

    /// Whether any part of this route was inferred. Cheaper than measuring it,
    /// for the callers that only need to decide whether to say anything.
    var containsInferredGeometry: Bool {
        dropFirst().contains(where: \.isInferred)
    }

    /// The stretches the recording was paused across, as runs of coordinates
    /// ready to hand to `MKPolyline`.
    ///
    /// One per boundary rather than per run: ``RouteBoundary`` marks the leg
    /// arriving at a point, and a resume produces exactly one such leg — the
    /// straight line from the last fix before the pause to the first fix
    /// after it. The predecessor is included for the same reason
    /// ``inferredSegments`` includes it, so the drawn stretch meets the rest
    /// of the line rather than floating beside it.
    ///
    /// Deliberately separate from ``inferredSegments``: the two say different
    /// things — "nobody watched this" against "nobody was asked to" — and a
    /// route can carry both. See ``RouteBoundary``.
    var pausedSegments: [[CLLocationCoordinate2D]] {
        guard count > 1 else { return [] }
        return (1..<count).compactMap { index in
            guard self[index].isPauseBoundary else { return nil }
            return [self[index - 1].clCoordinate, self[index].clCoordinate]
        }
    }

    /// Whether the recording was ever paused mid-walk. The first point is
    /// excluded because nothing precedes it to have been paused across.
    var containsPause: Bool {
        dropFirst().contains(where: \.isPauseBoundary)
    }
}
