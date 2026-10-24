//
//  TrailWalk.swift
//  OpenHikes
//
//  The value types behind a walk along a followed trail: the coverage union
//  a walk accrues, the numbers that decide when one is over, and the record
//  of one still under way.
//
//  Pure values, in the shape `FollowAnchor` and `OffRouteSearchPolicy` have,
//  so a suite can drive every rule here without a view, a store or a clock.
//  The live state — the one `@Observable` the screens read — is
//  ``TrailWalkSession``; nothing in this file knows it exists.
//

import Algorithms
import Foundation
import OpenHikesShared

/// The four numbers a walk is decided by. Proposals pinned by
/// `TrailWalkCoverageTests` and `TrailWalkSessionTests` rather than
/// measurements; change one there and here together.
nonisolated public enum TrailWalkPolicy {
    /// Two consecutive matches further apart than this along the route are
    /// not bridged: a re-acquisition after a lost signal must not paint the
    /// valley in between as walked. The same order as a background
    /// significant-change step.
    public static let gapBoundMeters: Double = 500
    /// A walk that covered less than this is not kept. Opening a trail at
    /// the trailhead for a look leaves no row behind.
    public static let minimumCoverageMeters: Double = 100
    /// A stretch walked back over ground walked the other way is a turn only
    /// from this long: shorter, inside a stretch of the other way's at least
    /// this long, it is a match that landed behind the one before it. The
    /// slack a match is allowed off the route, read along it — see
    /// ``TrailWalkCoverage/walkedTowardsStart``.
    public static let minimumTurnMeters: Double = RouteProfile.followMatchThresholdMeters
    /// Coverage at or above this, with a match this close to *either* end of
    /// the route, is the walk reaching the end on its own.
    ///
    /// Either end, because the direction a track is stored in is the
    /// importer's, not the hiker's: a route planned or shared by someone
    /// else is as likely to run the way they walk it as the other way round.
    /// Coverage is a union and never cared which way it was accrued, so
    /// measuring proximity to the stored end alone left a whole-route walk in
    /// the other direction reading 100% and never finishing. The coverage
    /// clause carries the *they actually walked it* requirement, so a hiker
    /// standing at the trailhead still completes nothing.
    public static let reachedEndFraction: Double = 0.95
    public static let reachedEndProximityMeters: Double = 50
    /// No on-route match for this long ends the walk as abandoned.
    ///
    /// A *following* walk only: a pause is the hiker saying the walk
    /// continues, and nothing advances a paused walk's last match — they are
    /// not moving, so no significant change wakes the background feed either.
    /// Measured against this, a hut evening or an overnight on a two-day
    /// trail would close the walk with the hiker looking at it.
    /// ``staleAtLaunchAfter`` is the backstop for a pause nobody came back to.
    public static let abandonAfter: TimeInterval = 6 * 3600
    /// A walk found still open at launch, whose last activity is older than
    /// this, is closed as abandoned before anything adopts it.
    public static let staleAtLaunchAfter: TimeInterval = 24 * 3600
    /// How often the walk in progress is written to the sidecar while it is
    /// accruing: the widget feed's own cadence, never per fix.
    public static let persistInterval: TimeInterval = 45

    /// Whether `coveredFraction` and a match `distanceToNearestEndMeters`
    /// from the nearer of the route's two ends amount to having reached it.
    public static func hasReachedEnd(coveredFraction: Double, distanceToNearestEndMeters: Double) -> Bool {
        coveredFraction >= reachedEndFraction && distanceToNearestEndMeters <= reachedEndProximityMeters
    }
}

/// Why a walk ended. Stored by raw value — like `routeLinePatternID` — so a
/// value a future build adds degrades on this one instead of failing to
/// decode.
nonisolated public enum TrailWalkEndReason: String, Codable, Hashable, Sendable {
    /// No on-route match for ``TrailWalkPolicy/abandonAfter``, or a walk
    /// found open at launch and older than ``TrailWalkPolicy/staleAtLaunchAfter``.
    case abandoned = "abandoned"
    /// The hiker tapped End.
    case ended = "ended"
    /// Coverage and proximity said the walk reached the route's end.
    case reachedEnd = "reachedEnd"
    /// The walk *was* the recording: a hike recorded and saved writes one row
    /// covering the whole of the route it just created — see
    /// ``HikeWalk/recorded(_:prepared:)``.
    ///
    /// A reason of its own rather than ``ended``, which it otherwise is: this
    /// is the only walk not accrued fix by fix along a trail that already
    /// existed, and a History list that also holds the follows made along the
    /// saved hike afterwards has to be able to say which row is the original.
    case recorded = "recorded"
    /// The hike's route was edited under the walk — here, or on the hiker's
    /// other device — so the line it was measured along no longer exists.
    ///
    /// Ended rather than carried over: the coverage is intervals along the
    /// *old* line, and neither its length nor its metres mean anything on a
    /// new one where a stop moved. Carried over, they finished a walk at the
    /// old end, halfway along an extended route. See
    /// ``TrailWalkRecord/routeRevision``.
    case routeChanged = "routeChanged"
}

/// Whether a walk is accruing coverage or deliberately not.
nonisolated public enum TrailWalkPhase: String, Codable, Hashable, Sendable {
    case following = "following"
    case paused = "paused"
}

/// The union of along-route intervals a walk's consecutive on-route matches
/// have spanned, which way each was walked, and the furthest point any of
/// them reached.
///
/// Coverage, not position. A hiker who opens the app on the return leg of
/// an out-and-back and walks to the end covers half the route, and this
/// says half where a position along the route would say all of it. Walking
/// a section twice adds nothing; skipping a section by road subtracts it.
///
/// Which way, because the climb depends on it and nothing else can say it
/// afterwards. The direction a route is stored in is its importer's, and a
/// walk from the stored end finishes like any other — see
/// ``TrailWalkPolicy/reachedEndFraction`` — so a union that forgot it put the
/// trail's ascent on the share card of a hiker who walked down it (#993).
/// Each way is a union of its own, so a stretch walked there and back is
/// climbed both ways and still covered once.
nonisolated public struct TrailWalkCoverage: Codable, Equatable, Sendable {
    /// Flat pairs in metres along the route, each written the way it was
    /// walked — where the stretch began, then where it ended — so a pair that
    /// runs downwards was walked towards the route's stored start.
    ///
    /// The pairs walked each way are merged and sorted by start among
    /// themselves, the ones towards the end first. Flat so the sidecar and
    /// the mirrored row store the same bytes, and the direction rides in the
    /// order of each pair rather than in a column of its own: a reader that
    /// wants only the ground covered takes each pair's lower and upper ends,
    /// whichever way round they are written. ``ranges`` is that reading,
    /// ``walkedTowardsEnd`` and ``walkedTowardsStart`` the directed ones.
    public private(set) var intervals: [Double] = []
    public private(set) var furthestDistanceMeters: Double = 0
    /// Where the last on-route match landed, or `nil` before the first. The
    /// next match extends the union from here — unless it is further away
    /// than ``TrailWalkPolicy/gapBoundMeters``, in which case it only moves
    /// this.
    public private(set) var lastMatchedDistance: Double?

    public init() {
        // The memberwise initialiser is private, since the union is.
    }

    /// The flat storage read as `(start, end)` pairs, dropping a trailing
    /// element with no partner rather than trapping on it.
    ///
    /// That rule is what every reader below needs, and what
    /// `stride(from: 0, to: intervals.count - 1, by: 2)` used to encode as an
    /// off-by-one: the `- 1` is the whole of what kept an odd-length array off
    /// `intervals[pair + 1]` and an empty one out of `0..<(-1)`. Load-bearing,
    /// non-obvious, and previously restated at each site. Stated once here.
    ///
    /// Lazy, because ``insert(from:to:)`` runs per on-route match while a
    /// walk is being recorded and should not allocate to read its own storage.
    private static func pairs(
        of intervals: [Double]
    ) -> some Sequence<(start: Double, end: Double)> {
        intervals.chunks(ofCount: 2).lazy.compactMap { chunk -> (start: Double, end: Double)? in
            guard chunk.count == 2, let start = chunk.first, let end = chunk.last else { return nil }
            return (start: start, end: end)
        }
    }

    /// The stored stretches walked one way — towards the route's stored start
    /// when `back`, towards its end otherwise — as ranges along the route. A
    /// pair with no length went nowhere, and reads as towards the end.
    private static func stretches(
        of intervals: [Double],
        back: Bool
    ) -> some Sequence<ClosedRange<Double>> {
        pairs(of: intervals).lazy.compactMap { pair -> ClosedRange<Double>? in
            guard (pair.end < pair.start) == back else { return nil }
            return min(pair.start, pair.end)...max(pair.start, pair.end)
        }
    }

    /// `stretch` as ``intervals`` stores it: low to high towards the end,
    /// high to low back.
    private static func pair(_ stretch: ClosedRange<Double>, back: Bool) -> [Double] {
        back ? [stretch.upperBound, stretch.lowerBound] : [stretch.lowerBound, stretch.upperBound]
    }

    /// The same union, from stored pairs. Pairs are trusted to be merged —
    /// they were written by ``record(distance:)`` — but re-merged anyway, each
    /// with the pairs walked its way, so a row edited by hand still reads as
    /// a union.
    public init(intervals: [Double], furthestDistanceMeters: Double) {
        var built = Self()
        for (start, end) in Self.pairs(of: intervals) {
            built.insert(from: start, to: end)
        }
        // A row whose furthest point was never written still reached the end
        // of its last pair.
        built.furthestDistanceMeters = max(furthestDistanceMeters, built.intervals.max() ?? 0)
        self = built
    }

    /// Folds in an on-route match at `distance` metres along the route.
    public mutating func record(distance: Double) {
        furthestDistanceMeters = max(furthestDistanceMeters, distance)
        defer { lastMatchedDistance = distance }
        guard let last = lastMatchedDistance,
              last != distance,
              abs(distance - last) <= TrailWalkPolicy.gapBoundMeters
        else { return }
        insert(from: last, to: distance)
    }

    /// Drops the continuity reference, so the next match starts a fresh
    /// interval the way a walk's first match does.
    ///
    /// What a pause needs, and what a confirmed off-route fix needs. The gap
    /// bound is the right rule for a lost signal — the hiker probably did
    /// walk the stretch in between — and it is exactly wrong when something
    /// says they did not: a pause is the hiker saying so, an accepted fix
    /// matched off the route is the matcher saying so. Without this, pausing
    /// at the col and walking 400 m down the ridge hands the union that
    /// 400 m on the first fix after Resume, and a road shortcut rejoined
    /// inside the bound hands it the section it skipped.
    public mutating func breakContinuity() {
        lastMatchedDistance = nil
    }

    /// The union's total length, in metres.
    public var coveredMeters: Double {
        ranges.reduce(0) { total, range in total + (range.upperBound - range.lowerBound) }
    }

    /// The ground covered, whichever way: both ways' stretches merged into
    /// one union, sorted by start.
    public var ranges: [ClosedRange<Double>] {
        let towardsStart = Array(Self.stretches(of: intervals, back: true))
        let towardsEnd = Array(Self.stretches(of: intervals, back: false))
        guard !towardsStart.isEmpty else { return towardsEnd }
        var union: [ClosedRange<Double>] = []
        for stretch in (towardsEnd + towardsStart).sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = union.last, stretch.lowerBound <= last.upperBound {
                union[union.count - 1] = last.lowerBound...max(last.upperBound, stretch.upperBound)
            } else {
                union.append(stretch)
            }
        }
        return union
    }

    /// The stretches walked the way the route's distances run, merged and
    /// sorted by start, less a step too short to be a turn — see
    /// ``walkedTowardsStart``.
    public var walkedTowardsEnd: [ClosedRange<Double>] {
        Self.turns(
            Array(Self.stretches(of: intervals, back: false)),
            against: Array(Self.stretches(of: intervals, back: true))
        )
    }

    /// The stretches walked back towards the route's stored start, merged and
    /// sorted by start. A stretch walked there and back is in both.
    ///
    /// Less a step too short to be a turn. Matches are not smoothed, and two
    /// feeds with two matchers supply them, so a walk that only ever went one
    /// way still has the odd match land behind the one before it; stored as
    /// walked back, that step would put a descent on the card of a walk
    /// straight up a hill. A stretch shorter than
    /// ``TrailWalkPolicy/minimumTurnMeters``, inside one of the other way's
    /// at least that long, is left out of both readings: a deadband along the
    /// route, as `ElevationAccumulator` keeps one on a height. Its ground is
    /// still covered, and ``ranges`` still counts it.
    public var walkedTowardsStart: [ClosedRange<Double>] {
        Self.turns(
            Array(Self.stretches(of: intervals, back: true)),
            against: Array(Self.stretches(of: intervals, back: false))
        )
    }

    /// `stretches` less each one too short to be a turn and lying inside one
    /// of `other`'s long enough to be one. Only a longer stretch leaves one
    /// out, so a short there and back keeps both ways.
    private static func turns(
        _ stretches: [ClosedRange<Double>],
        against other: [ClosedRange<Double>]
    ) -> [ClosedRange<Double>] {
        let minimum = TrailWalkPolicy.minimumTurnMeters
        return stretches.filter { stretch in
            stretch.upperBound - stretch.lowerBound >= minimum || !other.contains { outer in
                outer.upperBound - outer.lowerBound >= minimum
                    && outer.lowerBound <= stretch.lowerBound
                    && stretch.upperBound <= outer.upperBound
            }
        }
    }

    /// Covered length over the route's, clamped to 0…1 with the same
    /// arithmetic `RouteProfile.fractionComplete(atDistance:)` and
    /// `SharedTrailSnapshot.fractionComplete` share. `nil` for a route with
    /// no length, where a percentage would mean nothing.
    public func fractionComplete(routeDistanceMeters: Double) -> Double? {
        guard routeDistanceMeters > 0 else { return nil }
        return min(1, max(0, coveredMeters / routeDistanceMeters))
    }

    /// Whether this walk is worth keeping as a record.
    public var meetsMinimum: Bool {
        coveredMeters >= TrailWalkPolicy.minimumCoverageMeters
    }

    /// Adds the stretch walked from `start` to `end` to the union of those
    /// walked its way, merging every stored pair of that way it touches; the
    /// other way's pairs are copied as they stand. O(pairs), and a walk has
    /// as many pairs as it has gaps and turns.
    private mutating func insert(from start: Double, to end: Double) {
        let walksBack = end < start
        var mergedStart = min(start, end)
        var mergedEnd = max(start, end)
        var kept: [Double] = []
        kept.reserveCapacity(intervals.count + 2)
        // Towards the end first, then back, whatever order they were walked
        // in: the same ground walked the same ways stores the same bytes.
        for back in [false, true] {
            var placed = back != walksBack
            for stretch in Self.stretches(of: intervals, back: back) {
                if back != walksBack || stretch.upperBound < mergedStart {
                    kept.append(contentsOf: Self.pair(stretch, back: back))
                } else if stretch.lowerBound > mergedEnd {
                    if !placed {
                        kept.append(contentsOf: Self.pair(mergedStart...mergedEnd, back: back))
                        placed = true
                    }
                    kept.append(contentsOf: Self.pair(stretch, back: back))
                } else {
                    mergedStart = min(mergedStart, stretch.lowerBound)
                    mergedEnd = max(mergedEnd, stretch.upperBound)
                }
            }
            if !placed { kept.append(contentsOf: Self.pair(mergedStart...mergedEnd, back: back)) }
        }
        intervals = kept
    }
}

/// A walk still under way, as the sidecar stores it between milestones.
///
/// Device-local on purpose: a walk in progress is this phone's walk, and a
/// second device has no business showing it half-drawn. Written at
/// milestones — start, pause, resume, end — and otherwise at most every
/// ``TrailWalkPolicy/persistInterval``, never per fix. Ending a walk moves
/// it into a `HikeWalk` row and clears this in one save.
nonisolated public struct TrailWalkRecord: Codable, Equatable, Sendable {
    public var hikeID: UUID
    public var startedAt: Date
    public var coverage: TrailWalkCoverage
    /// Active time accrued before ``phaseChangedAt``. The current stretch,
    /// if the walk is following, is added on read — see
    /// ``activeSeconds(at:)``.
    public var bankedActiveSeconds: TimeInterval
    /// ``TrailWalkPhase`` by raw value, for the reason every stored enum here
    /// is.
    public var phaseID: String
    public var phaseChangedAt: Date
    /// When the last on-route match landed, matched or merely seen while
    /// paused. What ``TrailWalkPolicy/abandonAfter`` is measured from.
    public var lastMatchedAt: Date?
    /// Where along the route the last *walked* match was — the position the
    /// walk had reached, not the furthest it ever reached.
    ///
    /// Written only while following, which is what makes it the position the
    /// hiker paused at once they do: matches seen while paused move
    /// ``lastMatchedAt`` (they prove the walk is not abandoned) and must not
    /// move this, or the anchor a paused walk is measured against would
    /// follow the hiker and never register that they had moved at all.
    ///
    /// Optional because a walk can be paused before its first match.
    /// ``TrailWalkCoverage/furthestDistanceMeters`` is the fallback and is
    /// *not* an equivalent: it is a maximum, so a hiker who turned round and
    /// came back down before pausing would be measured against ground they
    /// left behind.
    public var lastFollowedDistanceMeters: Double?
    /// The route's length *at the time of the walk*: a route re-imported or
    /// edited later must not rewrite history.
    public var routeDistanceMeters: Double
    /// Which line the walk is along — ``routeRevision(of:)`` of the hike's
    /// route when the walk began — so an edit made under it can be noticed.
    ///
    /// Every distance in ``coverage`` is a distance along *that* line, and
    /// ``routeDistanceMeters`` alone cannot say whether it is still the one
    /// the matches are measured on: moving a stop can leave the length alone
    /// and still move every metre after it.
    ///
    /// Optional because a record written before this existed decodes without
    /// it; ``TrailWalkSession`` stamps one with the route it finds at launch.
    public var routeRevision: String?

    public init(hikeID: UUID, routeDistanceMeters: Double, startedAt: Date, routeRevision: String? = nil) {
        self.hikeID = hikeID
        self.routeDistanceMeters = routeDistanceMeters
        self.startedAt = startedAt
        self.routeRevision = routeRevision
        coverage = TrailWalkCoverage()
        bankedActiveSeconds = 0
        phaseID = TrailWalkPhase.following.rawValue
        phaseChangedAt = startedAt
        lastMatchedAt = startedAt
    }

    public var phase: TrailWalkPhase {
        get { TrailWalkPhase(rawValue: phaseID) ?? .following }
        set { phaseID = newValue.rawValue }
    }

    /// The clock minus its pauses, read at `now`.
    public func activeSeconds(at now: Date) -> TimeInterval {
        guard phase == .following else { return bankedActiveSeconds }
        return bankedActiveSeconds + max(0, now.timeIntervalSince(phaseChangedAt))
    }

    /// The moment the walk was last known to be on the route, for the
    /// abandonment rules.
    public var lastActivityAt: Date { lastMatchedAt ?? startedAt }

    public mutating func pause(at now: Date) {
        guard phase == .following else { return }
        bankedActiveSeconds = activeSeconds(at: now)
        phase = .paused
        phaseChangedAt = now
        // Whatever is walked while paused is not this walk's, and the first
        // match after a Resume must not be bridged back to here.
        coverage.breakContinuity()
    }

    public mutating func resume(at now: Date) {
        guard phase == .paused else { return }
        phase = .following
        phaseChangedAt = now
    }

    public var coveredFraction: Double {
        coverage.fractionComplete(routeDistanceMeters: routeDistanceMeters) ?? 0
    }

    /// Whether a match `distance` metres along the route is the walk
    /// reaching the end.
    ///
    /// Whichever end is nearer. A hiker who covered the route from its
    /// stored end to its stored start finishes at `distance` 0, and measuring
    /// to the stored end alone would call that the route's whole length away
    /// from finishing — see ``TrailWalkPolicy/reachedEndProximityMeters``.
    /// An out-and-back is unaffected: its two termini are the same place, and
    /// the walk that returns there is at `routeDistanceMeters` along the
    /// route, not at 0.
    public func reachesEnd(atMatch distance: Double) -> Bool {
        TrailWalkPolicy.hasReachedEnd(
            coveredFraction: coveredFraction,
            distanceToNearestEndMeters: max(0, min(distance, routeDistanceMeters - distance))
        )
    }

    /// Whether the walk has gone unmatched for long enough to count as
    /// abandoned.
    ///
    /// A paused walk never is — see ``TrailWalkPolicy/abandonAfter``. It is
    /// a walk nobody forgot: someone said *stop following*, and the only
    /// thing that would advance the clock this is measured from is the
    /// movement they just said they were not making.
    public func isAbandoned(at now: Date) -> Bool {
        guard phase == .following else { return false }
        return now.timeIntervalSince(lastActivityAt) > TrailWalkPolicy.abandonAfter
    }

    /// Whether a walk found still open at launch is too old to adopt.
    public func isStale(at now: Date) -> Bool {
        now.timeIntervalSince(lastActivityAt) > TrailWalkPolicy.staleAtLaunchAfter
    }

    /// Whether `route` is still the line this walk is along. A record with no
    /// revision says yes: there is nothing to tell an edit from.
    public func isAlong(_ route: [RouteCoordinate]) -> Bool {
        guard let routeRevision else { return true }
        return routeRevision == Self.routeRevision(of: route)
    }

    /// This record, taken to be along `route` if it does not say which line
    /// it is along. The one it already names is kept.
    public func stamped(along route: [RouteCoordinate]) -> Self {
        guard routeRevision == nil else { return self }
        var stamped = self
        stamped.routeRevision = Self.routeRevision(of: route)
        return stamped
    }

    /// The line `route` draws, as a stable hash of its coordinates.
    ///
    /// Positions only. A height filled in or a timestamp dropped leaves every
    /// distance along the route where it was, and ending a walk over one
    /// would end it for an edit that changed nothing it measures.
    public static func routeRevision(of route: [RouteCoordinate]) -> String {
        var hasher = StableHasher()
        for point in route {
            hasher.combine(point.latitude)
            hasher.combine(point.longitude)
        }
        return String(hasher.value, radix: 16)
    }
}
