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
//  more than one fix — dated from when they set off, and carrying the
//  coverage it saw on the way, so a confirmed walk is the walk it would
//  always have been. From a loop's trailhead, which is both of its ends,
//  that is read the shorter way round as well — see ``shorterWay``.
//  Nothing here is published, persisted or drawn: a proposal is the
//  session's private business until it confirms.
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
    /// be seen in — see ``Departure/steps``.
    static let confirmingSteps = 2
    /// How long a proposal waits for its next match before it is forgotten.
    /// A hiker who stood here an hour ago and is back now is starting from
    /// now; yesterday's spot is not where today's walk set off.
    static let expiresAfter: TimeInterval = 30 * 60

    /// The walk as it would stand if it started now, minus its date.
    private(set) var record: TrailWalkRecord
    /// Where along the route the first match put the hiker.
    private let originMeters: Double
    /// How far apart the route's two ends are, when the first match put the
    /// hiker within ``stillRadiusMeters`` of one of them, and `nil` when it
    /// put them anywhere else: the gap the way round, through the ends, has
    /// to cross — see ``shorterWay``.
    private let gapThroughEndsMeters: Double?
    /// The last match within ``stillRadiusMeters`` of that spot, read the
    /// shorter way: when the hiker set off, and what a confirmed walk is
    /// dated from.
    private var setOffAt: Date
    /// The matches read straight along the route.
    private var straightAlong = Departure()
    /// The matches read the shorter way: straight along, or — from a
    /// trailhead both of the route's ends share — round through the ends.
    ///
    /// A hiker found at a loop's trailhead who sets off the other way round
    /// from the way it is stored is matched at its start until they are out
    /// of the start's reach, and then near its end: most of the route away
    /// read straight along, and every step after that one nearer, so the walk
    /// never started. Read round through the trailhead, each step is further
    /// out, until the hiker is halfway round. A gap between the ends is
    /// crossed as the crow flies: a loop recorded a little short of where it
    /// began reads like one that closes, and the far end of a trail between
    /// two places is never nearer than the ground between them.
    ///
    /// Beside the straight reading rather than instead of it, because the way
    /// round is the shorter only until halfway round, and past that point a
    /// route can come back through its trailhead: a figure-eight whose
    /// trailhead is its crossing, or two loops from one car park recorded as
    /// one hike. Setting off along that later pass, each step is further
    /// along the route and nearer round it, so read the shorter way alone,
    /// that walk would never start; straight along, it starts as it always
    /// did. And the shorter way, not the way round: a phone at the trailhead
    /// that snaps a few hundred metres along and drifts back is further round
    /// each time, which would count as steps out of a walk.
    ///
    /// From the trailhead only. Anywhere else the way round is the shorter
    /// only for a match more than halfway round, by when the straight reading
    /// has long since started the walk, so it would be one more way for a
    /// stray match to count and nothing else.
    private var shorterWay = Departure()

    /// - Parameter endsApartMeters: how far apart the route's two ends are
    ///   on the ground — see ``endsApartMeters(of:)``.
    init(
        hikeID: UUID,
        routeDistanceMeters: Double,
        endsApartMeters: Double,
        routeRevision: String?,
        distance: Double,
        at date: Date
    ) {
        record = TrailWalkRecord(
            hikeID: hikeID,
            routeDistanceMeters: routeDistanceMeters,
            startedAt: date,
            routeRevision: routeRevision
        )
        originMeters = distance
        let fromNearerEnd = min(distance, routeDistanceMeters - distance)
        gapThroughEndsMeters = fromNearerEnd <= Self.stillRadiusMeters ? endsApartMeters : nil
        setOffAt = date
        record.coverage.record(distance: distance)
        record.lastFollowedDistanceMeters = distance
    }

    /// How far apart `profile`'s two ends are on the ground: nothing on a
    /// loop or an out-and-back, the trail's span on one between two places.
    static func endsApartMeters(of profile: RouteProfile) -> Double {
        guard let start = profile.coordinate(atDistance: 0),
              let end = profile.coordinate(atDistance: profile.totalDistanceMeters)
        else { return .infinity }
        return RouteGeometry.distanceMeters(from: start, to: end)
    }

    var hikeID: UUID { record.hikeID }

    /// Another on-route match along the same trail.
    mutating func record(distance: Double, at date: Date) {
        // Out of order says nothing new, as it does for a walk under way.
        guard date >= record.lastActivityAt else { return }
        record.coverage.record(distance: distance)
        record.lastMatchedAt = date
        record.lastFollowedDistanceMeters = distance
        let along = abs(distance - originMeters)
        let shorter = gapThroughEndsMeters.map { min(along, record.routeDistanceMeters - along + $0) } ?? along
        // Still, read either way: a hiker at a loop's trailhead is matched
        // either side of the join, and both are where they stand. On a loop
        // under about 150 m the hiker is back that near the trailhead before
        // they are far enough from it to have set off, so only Start begins
        // a walk there.
        if shorter <= Self.stillRadiusMeters {
            setOffAt = date
            straightAlong = Departure()
            shorterWay = Departure()
        } else {
            straightAlong.record(along)
            shorterWay.record(shorter)
        }
    }

    /// Whether the hiker has walked far enough along the route to be walking
    /// it: far enough from the spot it found them, in more than one step
    /// outwards, with the stretch between actually covered rather than
    /// bridged by a jump the coverage refused.
    var isConfirmed: Bool {
        (straightAlong.isConfirmed || shorterWay.isConfirmed) && record.coverage.meetsMinimum
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

    /// How far out one reading of the matches has seen the hiker go since
    /// they set off.
    private struct Departure: Equatable {
        /// The furthest a match has landed from the origin, read this way,
        /// since the hiker set off — which a hiker standing still does not
        /// grow, however long they stand.
        private(set) var meters: Double = 0
        /// How many matches since setting off have each landed further from
        /// the origin than any before them, read this way.
        ///
        /// A walk is a run of fixes working outwards. One fix that lands a
        /// few hundred metres along is not that: GPS re-acquiring, or a phone
        /// indoors snapping to another spot on the trail, puts a single match
        /// anywhere the coverage will bridge, and a snapped phone that stays
        /// snapped repeats the same spot rather than moving past it.
        private(set) var steps = 0

        /// Far enough from the spot the proposal found the hiker, in more
        /// than one step outwards.
        var isConfirmed: Bool {
            meters >= PendingWalkStart.confirmingMeters && steps >= PendingWalkStart.confirmingSteps
        }

        /// A match `fromOrigin` metres from the origin, read this way.
        mutating func record(_ fromOrigin: Double) {
            guard fromOrigin > meters else { return }
            meters = fromOrigin
            steps += 1
        }
    }
}
