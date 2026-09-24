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
}

/// Whether a walk is accruing coverage or deliberately not.
nonisolated public enum TrailWalkPhase: String, Codable, Hashable, Sendable {
    case following = "following"
    case paused = "paused"
}

/// The union of along-route intervals a walk's consecutive on-route matches
/// have spanned, and the furthest point any of them reached.
///
/// Coverage, not position. A hiker who opens the app on the return leg of
/// an out-and-back and walks to the end covers half the route, and this
/// says half where a position along the route would say all of it. Walking
/// a section twice adds nothing; skipping a section by road subtracts it.
nonisolated public struct TrailWalkCoverage: Codable, Equatable, Sendable {
    /// Flat `start, end` pairs in metres along the route, merged and sorted
    /// by start. Flat so the sidecar and the mirrored row store the same
    /// bytes; ``ranges`` is the structured reading.
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
    /// That rule is what the three readers below all need, and what
    /// `stride(from: 0, to: intervals.count - 1, by: 2)` used to encode as an
    /// off-by-one: the `- 1` is the whole of what kept an odd-length array off
    /// `intervals[pair + 1]` and an empty one out of `0..<(-1)`. Load-bearing,
    /// non-obvious, and previously restated at each site. Stated once here.
    ///
    /// Lazy, because ``insert(_:_:)`` runs per on-route match while a walk is
    /// being recorded and should not allocate to read its own storage.
    private static func pairs(
        of intervals: [Double]
    ) -> some Sequence<(start: Double, end: Double)> {
        intervals.chunks(ofCount: 2).lazy.compactMap { chunk -> (start: Double, end: Double)? in
            guard chunk.count == 2, let start = chunk.first, let end = chunk.last else { return nil }
            return (start: start, end: end)
        }
    }

    /// The same union, from stored pairs. Pairs are trusted to be merged —
    /// they were written by ``record(distance:)`` — but re-merged anyway, so
    /// a row edited by hand still reads as a union.
    public init(intervals: [Double], furthestDistanceMeters: Double) {
        var built = Self()
        for (start, end) in Self.pairs(of: intervals) {
            built.insert(min(start, end), max(start, end))
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
        insert(min(last, distance), max(last, distance))
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

    public var ranges: [ClosedRange<Double>] {
        Self.pairs(of: intervals).map { $0.start...$0.end }
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

    /// Adds `[start, end]` to the union, merging every stored pair it
    /// touches. O(pairs), and a walk has as many pairs as it has gaps.
    private mutating func insert(_ start: Double, _ end: Double) {
        var mergedStart = start
        var mergedEnd = end
        var kept: [Double] = []
        kept.reserveCapacity(intervals.count + 2)
        var placed = false
        for (lower, upper) in Self.pairs(of: intervals) {
            if upper < mergedStart {
                kept.append(contentsOf: [lower, upper])
            } else if lower > mergedEnd {
                if !placed {
                    kept.append(contentsOf: [mergedStart, mergedEnd])
                    placed = true
                }
                kept.append(contentsOf: [lower, upper])
            } else {
                mergedStart = min(mergedStart, lower)
                mergedEnd = max(mergedEnd, upper)
            }
        }
        if !placed { kept.append(contentsOf: [mergedStart, mergedEnd]) }
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

    public init(hikeID: UUID, routeDistanceMeters: Double, startedAt: Date) {
        self.hikeID = hikeID
        self.routeDistanceMeters = routeDistanceMeters
        self.startedAt = startedAt
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
}
