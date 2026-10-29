//
//  HikeWalkPhotoTimeline.swift
//  OpenHikes
//
//  Where the hiker had got to during a *walk* along a trail, for a trail whose
//  own route cannot say.
//
//  ``HikePhotoTimeline`` reads the route's per-point timestamps, which is the
//  right answer for a hike this app recorded and no answer at all for one that
//  arrived as a GPX. An imported track carries the original recorder's clock
//  or no clock at all, so a hiker who imports a route, walks it today and
//  photographs it with the system camera gets a scan whose window is somebody
//  else's afternoon — and a screen telling them their walk had no photographs.
//
//  What the app does know about that walk is a ``HikeWalk``: when it started,
//  when it ended, and the union of the route it covered in metres. That is a
//  window and a stretch, not a clock, and this type is deliberately the weaker
//  thing rather than a second one pretending to be ``HikePhotoTimeline``.
//
//  The stretch is metres along the route *as it was walked*, and a route can
//  change under its walks — *Edit Route* keeps a drawn trail's walks as
//  history — so it is read only for a walk along the line the hike has now.
//  Any other walk is left out whole rather than placed by distances that name
//  other ground: see ``Hike/walkPhotoTimelines``.
//
//  Two honest limits are worth stating outright, because both bound what the
//  placement below is worth.
//
//  The union is a stretch, not a path in walking order. Coverage keeps which
//  way each stretch was walked, but never the order the stretches came in.
//  A walk that went one way throughout is placed the way it went: up through
//  the union when it walked towards the route's stored end, and down through
//  it from the top when it set out from the stored end, which a route planned
//  by someone else is as likely to be walked from (#1040). A walk with
//  stretches both ways — an out-and-back covers its outward half twice, and
//  the union holds it once — has no order this can read, so it is placed in
//  the order the route is written in: the way the usual out-and-back sets
//  out, and a guess whichever way it went.
//
//  And the fraction is of wall-clock time, not of ``HikeWalk/activeSeconds``.
//  A walk records how long it was actually moving but not *when* it was
//  stopped, so an hour at the summit cannot be subtracted from the right part
//  of the afternoon; spreading it evenly is the only thing the stored row
//  supports. A photograph taken after a long pause is therefore placed further
//  along than the hiker had really got.
//
//  Which is why nothing here is presented as a measurement. A photo placed by
//  a walk carries ``PhotoMatchEvidence/walk``, the review grid says so in as
//  many words, and the user taps the ones that belong — the same contract the
//  rest of this feature is built on.
//

import Foundation
import OpenHikesData

nonisolated struct HikeWalkPhotoTimeline: Equatable, Sendable {
    /// How far off the covered union a photograph's own position may be and
    /// still be taken as part of this walk.
    ///
    /// The union's ends are where on-route *matches* landed, and a walk is
    /// matched at the cadence the significant-change feed wakes it at rather
    /// than continuously — so the stretch either side of an interval is
    /// routinely walked without being recorded as covered. A hundred metres is
    /// the same slack ``LibraryPhotoMatcher/maximumOffRouteMeters`` allows
    /// perpendicular to the route, applied along it.
    static let coverageSlackMeters: Double = 100

    let startedAt: Date
    let endedAt: Date
    /// The covered union as ranges in metres along the route, ascending and
    /// merged, whichever way each stretch was walked —
    /// ``TrailWalkCoverage/ranges``.
    let ranges: [ClosedRange<Double>]
    /// The union's total length, which is the distance ``distanceAlongRoute(at:)``
    /// spreads the walk's clock over.
    let coveredMeters: Double
    /// Whether every stretch of the walk went back towards the route's stored
    /// start, so progress runs down through ``ranges`` from the top — see the
    /// limits in this file's header. Read from
    /// ``TrailWalkCoverage/walkedTowardsEnd`` and
    /// ``TrailWalkCoverage/walkedTowardsStart``, which already leave out a
    /// match that landed a step behind the one before it, so the odd step
    /// back in a walk from the stored end does not make it a walk both ways.
    let walkedTowardsStart: Bool

    /// `nil` for a walk that covered nothing, or whose stored clock runs
    /// backwards — neither can place anything, and a window opened on either
    /// would only widen the fetch.
    init?(startedAt: Date, endedAt: Date, coverage: TrailWalkCoverage) {
        let walked = coverage.ranges.filter { $0.upperBound > $0.lowerBound }
        guard !walked.isEmpty, endedAt >= startedAt else { return nil }
        self.startedAt = startedAt
        self.endedAt = endedAt
        ranges = walked
        coveredMeters = walked.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) }
        walkedTowardsStart = coverage.walkedTowardsEnd.isEmpty && !coverage.walkedTowardsStart.isEmpty
    }

    /// Every moment a photograph of this walk could carry, with the same grace
    /// at both ends that a recorded route is given: the trailhead photo taken
    /// while the walk was still being started is real.
    var searchWindow: ClosedRange<Date> {
        let earliest = startedAt.addingTimeInterval(-HikePhotoTimeline.graceInterval)
        let latest = endedAt.addingTimeInterval(HikePhotoTimeline.graceInterval)
        return earliest...latest
    }

    /// How far along the route the walk had got at `date`, by even progress
    /// through the covered union in the direction it was walked — see the
    /// limits in this file's header.
    ///
    /// `nil` only for a date outside ``searchWindow``. Inside the grace at
    /// either end the answer is the walk's end nearest it, for the same reason
    /// ``HikePhotoTimeline/position(at:)`` gives one there.
    func distanceAlongRoute(at date: Date) -> Double? {
        guard searchWindow.contains(date) else { return nil }
        let span = endedAt.timeIntervalSince(startedAt)
        // A walk stored with one instant for both ends covered its union in no
        // time at all; there is no fraction to take, and its start is the only
        // position it can honestly offer.
        let fraction = span > 0 ? min(max(0, date.timeIntervalSince(startedAt)), span) / span : 0
        let walkedMeters = coveredMeters * fraction
        // Walked down from the top, a distance into the walk is the same
        // distance short of the union's top, which is the rest of the union
        // counted up from the bottom: the measure is the same either way.
        var remaining = walkedTowardsStart ? coveredMeters - walkedMeters : walkedMeters
        for range in ranges {
            let length = range.upperBound - range.lowerBound
            if remaining <= length { return range.lowerBound + remaining }
            remaining -= length
        }
        // Only reachable through floating-point drift across the sum above,
        // and the top of the union is what the distance was asking for.
        return ranges[ranges.count - 1].upperBound
    }

    /// Whether a point this far along the route is part of what this walk
    /// covered, within ``coverageSlackMeters``.
    ///
    /// The test the walk adds that a bare route cannot: a photograph taken
    /// at the far end of a trail, during the afternoon a hiker walked only its
    /// first kilometre, is a photograph of the trail and not of the walk.
    func covers(_ distanceAlongRoute: Double) -> Bool {
        ranges.contains { range in
            distanceAlongRoute >= range.lowerBound - Self.coverageSlackMeters
                && distanceAlongRoute <= range.upperBound + Self.coverageSlackMeters
        }
    }
}

extension Hike {
    /// This hike's finished walks as photo timelines, oldest first — the walks
    /// along the line the hike has now, and no others.
    ///
    /// A walk's stretches are metres along the route as it stood when the walk
    /// ended, and *Edit Route* keeps a drawn trail's walks as history, so after
    /// an edit the same distances name other ground: the far end of a reversed
    /// line, a different bend of a rerouted one. A walk along another line is
    /// left out whole. Its window could still say *when* the hiker was out, but
    /// nothing then says *where*, which is the half the stretches carried, and
    /// placing a photograph by a stretch that is no longer the walker's would
    /// pin it to ground they never reached. A walk that records no line is
    /// along none, the strictness ``HikeWalk/isAlong(revision:)`` states and
    /// the walk summary already applies.
    ///
    /// Read from the relationship rather than through `HikeWalk`'s `hikeID`
    /// column, because this is the one question that wants the walks *of this
    /// row* and has no list to rank — the reason the relationship exists at
    /// all beyond its cascade.
    ///
    /// `nonisolated`, because a photo search reads it off the main actor
    /// from a context of its own — see ``HikePhotoSearchPlan/SourceRead``.
    nonisolated var walkPhotoTimelines: [HikeWalkPhotoTimeline] {
        walksAlongCurrentRoute
            .compactMap(Self.photoTimeline(of:))
            .sorted { $0.startedAt < $1.startedAt }
    }

    /// Whether ``walkPhotoTimelines`` would hold anything — all a caption
    /// needs — without building every timeline and sorting them to find out.
    var hasWalkPhotoTimeline: Bool {
        walksAlongCurrentRoute.contains { Self.photoTimeline(of: $0) != nil }
    }

    /// The finished walks along the line the hike has now, by the rule
    /// ``walkPhotoTimelines`` states.
    nonisolated private var walksAlongCurrentRoute: [HikeWalk] {
        let finished = walks ?? []
        // The revision reads every point of the route, so a hike with no walks
        // — most of them — never pays for it.
        guard !finished.isEmpty else { return [] }
        let revision = TrailWalkRecord.routeRevision(of: route)
        return finished.filter { $0.isAlong(revision: revision) }
    }

    nonisolated private static func photoTimeline(of walk: HikeWalk) -> HikeWalkPhotoTimeline? {
        HikeWalkPhotoTimeline(
            startedAt: walk.startedAt,
            endedAt: walk.endedAt,
            coverage: walk.coverage
        )
    }
}
