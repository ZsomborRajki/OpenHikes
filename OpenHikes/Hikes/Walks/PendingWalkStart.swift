//
//  PendingWalkStart.swift
//  OpenHikes
//
//  A walk a matched fix has proposed and movement has not yet confirmed.
//
//  Auto-start used to begin a walk on the first fix that matched the route,
//  and a fix says where the hiker is, not that they are walking. Open a
//  trail that passes the front door and a walk started on the sofa: the pill,
//  the controls, a Lock Screen panel, and a screen kept awake, for a walk
//  that was going to be thrown away at its End for covering nothing — and
//  that held every other trail's auto-start back for the six hours it took
//  to be abandoned.
//
//  So the first match proposes, and the walk starts only once the hiker has
//  moved ``confirmingMeters`` along the route from where it found them, in
//  more than one fix —
//  dated from when they set off, and carrying the coverage it saw on the
//  way, so a confirmed walk is the walk it would always have been. Nothing
//  here is published, persisted or drawn: a proposal is the session's
//  private business until it confirms.
//
//  A pure value, like ``TrailWalkRecord`` beside it, so every rule here is a
//  suite with no view, store or clock.
//

import Foundation
import OpenHikesData

struct PendingWalkStart: Equatable {
    /// How far from where the proposal found the hiker a match has to land
    /// before it is a walk. The minimum a walk needs to be kept, so a walk
    /// that starts is never one an End would throw away.
    static let confirmingMeters = TrailWalkPolicy.minimumCoverageMeters
    /// How close to that spot a match still counts as not having set off.
    /// Half the confirming distance, so the two cannot overlap.
    static let stillRadiusMeters = confirmingMeters / 2
    /// How many matches, each further out than the last, setting off has to
    /// be seen in — see ``stepsOut``.
    static let confirmingSteps = 2
    /// How long a proposal waits for its next match before it is forgotten.
    /// A hiker who stood here an hour ago and is back now is starting from
    /// now; yesterday's spot is not where today's walk set off.
    static let expiresAfter: TimeInterval = 30 * 60

    /// The walk as it would stand if it started now, minus its date.
    private(set) var record: TrailWalkRecord
    /// Where along the route the first match put the hiker.
    private let originMeters: Double
    /// The last match still within ``stillRadiusMeters`` of that spot: when
    /// the hiker set off, and what a confirmed walk is dated from.
    private var setOffAt: Date
    /// The furthest a match has landed from the origin, either way along the
    /// route, since the hiker set off — which a hiker standing still does not
    /// grow, however long they stand. Back to zero whenever a match puts them
    /// at the origin again, as ``setOffAt`` moves.
    private var departureMeters: Double = 0
    /// How many matches since setting off have each landed further from the
    /// origin than any before them.
    ///
    /// A walk is a run of fixes working outwards. One fix that lands a few
    /// hundred metres along is not that: GPS re-acquiring, or a phone indoors
    /// snapping to another spot on the trail, puts a single match anywhere
    /// the coverage will bridge, and a snapped phone that stays snapped
    /// repeats the same spot rather than moving past it.
    private var stepsOut = 0

    init(hikeID: UUID, routeDistanceMeters: Double, routeRevision: String?, distance: Double, at date: Date) {
        record = TrailWalkRecord(
            hikeID: hikeID,
            routeDistanceMeters: routeDistanceMeters,
            startedAt: date,
            routeRevision: routeRevision
        )
        originMeters = distance
        setOffAt = date
        record.coverage.record(distance: distance)
        record.lastFollowedDistanceMeters = distance
    }

    var hikeID: UUID { record.hikeID }

    /// Another on-route match along the same trail.
    mutating func record(distance: Double, at date: Date) {
        // Out of order says nothing new, as it does for a walk under way.
        guard date >= record.lastActivityAt else { return }
        record.coverage.record(distance: distance)
        record.lastMatchedAt = date
        record.lastFollowedDistanceMeters = distance
        let fromOrigin = abs(distance - originMeters)
        if fromOrigin <= Self.stillRadiusMeters {
            setOffAt = date
            departureMeters = 0
            stepsOut = 0
        } else if fromOrigin > departureMeters {
            departureMeters = fromOrigin
            stepsOut += 1
        }
    }

    /// Whether the hiker has walked far enough along the route to be walking
    /// it: far enough from the spot it found them, in more than one step
    /// outwards, with the stretch between actually covered rather than
    /// bridged by a jump the coverage refused.
    var isConfirmed: Bool {
        departureMeters >= Self.confirmingMeters
            && stepsOut >= Self.confirmingSteps
            && record.coverage.meetsMinimum
    }

    func isExpired(at now: Date) -> Bool {
        now.timeIntervalSince(record.lastActivityAt) > Self.expiresAfter
    }

    /// The walk this proposal confirms, begun when the hiker set off.
    var confirmedRecord: TrailWalkRecord {
        var walk = record
        walk.startedAt = setOffAt
        walk.phaseChangedAt = setOffAt
        return walk
    }
}
