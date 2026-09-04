//
//  HikeWalk.swift
//  OpenHikes
//
//  One finished walk along a hike: when it was walked, for how long, and how
//  much of the route it covered.
//
//  A `@Model` in the mirrored store rather than a value array on `Hike` like
//  `photos`, for three reasons. The History segment wants a `@Query` that a
//  write to the `Hike` — a title edit, a tint change, the auto-follow toggle —
//  does not invalidate. A walk row wants to be a `SheetRoute` case that can
//  be pushed and popped by identity. And the cascade on the relationship is
//  what takes the walks with the hike without a new deletion step.
//
//  A walk is a fact about the walker, not about the phone, so it syncs. The
//  host is a `Hike` whichever way it arrived — an imported GPX or a saved
//  recording — and no column records which, because the host already knows.
//
//  Append-only from the day it ships: the mirrored CloudKit schema never
//  lets a column change type or go away, which is why `endReasonID` is a
//  string and `coveredIntervals` a flat `[Double]` rather than a nested type
//  that might want a field later.
//

import Foundation
import SwiftData

@Model
final class HikeWalk {
    /// `id` for identity lookups, `hikeID` for the History segment's query,
    /// `startedAt` for its sort. `#Index` rather than `#Unique` for the reason
    /// `Hike` has neither: mirroring forbids a uniqueness constraint outright.
    #Index<HikeWalk>([\.id], [\.hikeID], [\.startedAt])

    // Every non-optional column carries an inline default, because mirroring
    // refuses to open a store whose mandatory attributes cannot be backfilled.

    var id = UUID()
    /// The host's id, by value. The relationship below is what cascades; this
    /// is what the History query filters on, and it is indexed for that.
    var hikeID = UUID()
    /// The host. Optional and inversed, both required by CloudKit mirroring.
    var hike: Hike?
    var startedAt = Date.distantPast
    /// A real value on every stored row: a walk still under way is not a row
    /// but a column on the sidecar — see `HikeLocalState.walkInProgress`.
    var endedAt = Date.distantPast
    /// The clock minus pauses.
    var activeSeconds: Double = 0
    /// Flat start/end pairs along the route, in metres — the merged union.
    var coveredIntervals: [Double] = []
    var furthestDistanceMeters: Double = 0
    /// The route's length at the time of the walk. A route re-imported or
    /// edited later must not rewrite history.
    var routeDistanceMeters: Double = 0
    /// ``TrailWalkEndReason`` by raw value.
    var endReasonID: String = TrailWalkEndReason.ended.rawValue

    init(
        hikeID: UUID,
        startedAt: Date,
        endedAt: Date,
        activeSeconds: Double,
        coveredIntervals: [Double],
        furthestDistanceMeters: Double,
        routeDistanceMeters: Double,
        endReason: TrailWalkEndReason,
        id: UUID = UUID()
    ) {
        self.id = id
        self.hikeID = hikeID
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.activeSeconds = activeSeconds
        self.coveredIntervals = coveredIntervals
        self.furthestDistanceMeters = furthestDistanceMeters
        self.routeDistanceMeters = routeDistanceMeters
        endReasonID = endReason.rawValue
    }
}

extension HikeWalk {
    /// The stored reason, or `nil` for a value this build does not know.
    var endReason: TrailWalkEndReason? { TrailWalkEndReason(rawValue: endReasonID) }

    var coverage: TrailWalkCoverage {
        TrailWalkCoverage(intervals: coveredIntervals, furthestDistanceMeters: furthestDistanceMeters)
    }

    /// Covered length over the route's length at the time, 0…1.
    var coveredFraction: Double {
        coverage.fractionComplete(routeDistanceMeters: routeDistanceMeters) ?? 0
    }

    /// The part of the route the walk did not cover, in metres.
    var uncoveredMeters: Double {
        max(0, routeDistanceMeters - coverage.coveredMeters)
    }

    /// The walk's record, frozen from `record` at `endedAt`.
    convenience init(closing record: TrailWalkRecord, at endedAt: Date, reason: TrailWalkEndReason) {
        self.init(
            hikeID: record.hikeID,
            startedAt: record.startedAt,
            endedAt: endedAt,
            activeSeconds: record.activeSeconds(at: endedAt),
            coveredIntervals: record.coverage.intervals,
            furthestDistanceMeters: record.coverage.furthestDistanceMeters,
            routeDistanceMeters: record.routeDistanceMeters,
            endReason: reason
        )
    }
}
