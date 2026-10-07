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
//  moved ``confirmingMeters`` along the route from where it found them —
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
    /// The furthest any match has landed from the origin, either way along
    /// the route — which a hiker standing still does not grow, however long
    /// they stand.
    private var departureMeters: Double = 0

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
        departureMeters = max(departureMeters, fromOrigin)
        if fromOrigin <= Self.stillRadiusMeters { setOffAt = date }
    }

    /// Whether the hiker has walked far enough along the route to be walking
    /// it: far enough from the spot it found them, with the stretch between
    /// actually covered rather than bridged by a jump the coverage refused.
    var isConfirmed: Bool {
        departureMeters >= Self.confirmingMeters && record.coverage.meetsMinimum
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
