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

import Foundation

/// The four numbers a walk is decided by. Proposals pinned by
/// `TrailWalkCoverageTests` and `TrailWalkSessionTests` rather than
/// measurements; change one there and here together.
nonisolated enum TrailWalkPolicy {
    /// Two consecutive matches further apart than this along the route are
    /// not bridged: a re-acquisition after a lost signal must not paint the
    /// valley in between as walked. The same order as a background
    /// significant-change step.
    static let gapBoundMeters: Double = 500
    /// A walk that covered less than this is not kept. Opening a trail at
    /// the trailhead for a look leaves no row behind.
    static let minimumCoverageMeters: Double = 100
    /// Coverage at or above this, with a match this close to the route's
    /// end, is the walk reaching the end on its own.
    static let reachedEndFraction: Double = 0.95
    static let reachedEndProximityMeters: Double = 50
    /// No on-route match for this long ends the walk as abandoned.
    static let abandonAfter: TimeInterval = 6 * 3600
    /// A walk found still open at launch, whose last activity is older than
    /// this, is closed as abandoned before anything adopts it.
    static let staleAtLaunchAfter: TimeInterval = 24 * 3600
    /// How often the walk in progress is written to the sidecar while it is
    /// accruing: the widget feed's own cadence, never per fix.
    static let persistInterval: TimeInterval = 45

    /// Whether `coveredFraction` and a match `distanceToEndMeters` from the
    /// route's end amount to having reached it.
    static func hasReachedEnd(coveredFraction: Double, distanceToEndMeters: Double) -> Bool {
        coveredFraction >= reachedEndFraction && distanceToEndMeters <= reachedEndProximityMeters
    }
}

/// Why a walk ended. Stored by raw value — like `routeLinePatternID` — so a
/// value a future build adds degrades on this one instead of failing to
/// decode.
nonisolated enum TrailWalkEndReason: String, Codable, Hashable, Sendable {
    /// No on-route match for ``TrailWalkPolicy/abandonAfter``, or a walk
    /// found open at launch and older than ``TrailWalkPolicy/staleAtLaunchAfter``.
    case abandoned = "abandoned"
    /// The walker tapped End.
    case ended = "ended"
    /// Coverage and proximity said the walk reached the route's end.
    case reachedEnd = "reachedEnd"
}

/// Whether a walk is accruing coverage or deliberately not.
nonisolated enum TrailWalkPhase: String, Codable, Hashable, Sendable {
    case following = "following"
    case paused = "paused"
}

/// The union of along-route intervals a walk's consecutive on-route matches
/// have spanned, and the furthest point any of them reached.
///
/// Coverage, not position. A walker who opens the app on the return leg of
/// an out-and-back and walks to the end covers half the route, and this
/// says half where a position along the route would say all of it. Walking
/// a section twice adds nothing; skipping a section by road subtracts it.
nonisolated struct TrailWalkCoverage: Codable, Equatable, Sendable {
    /// Flat `start, end` pairs in metres along the route, merged and sorted
    /// by start. Flat so the sidecar and the mirrored row store the same
    /// bytes; ``ranges`` is the structured reading.
    private(set) var intervals: [Double] = []
    private(set) var furthestDistanceMeters: Double = 0
    /// Where the last on-route match landed, or `nil` before the first. The
    /// next match extends the union from here — unless it is further away
    /// than ``TrailWalkPolicy/gapBoundMeters``, in which case it only moves
    /// this.
    private(set) var lastMatchedDistance: Double?

    init() {
        // The memberwise initialiser is private, since the union is.
    }

    /// The same union, from stored pairs. Pairs are trusted to be merged —
    /// they were written by ``record(distance:)`` — but re-merged anyway, so
    /// a row edited by hand still reads as a union.
    init(intervals: [Double], furthestDistanceMeters: Double) {
        var built = Self()
        for pair in stride(from: 0, to: intervals.count - 1, by: 2) {
            built.insert(min(intervals[pair], intervals[pair + 1]), max(intervals[pair], intervals[pair + 1]))
        }
        // A row whose furthest point was never written still reached the end
        // of its last pair.
        built.furthestDistanceMeters = max(furthestDistanceMeters, built.intervals.max() ?? 0)
        self = built
    }

    /// Folds in an on-route match at `distance` metres along the route.
    mutating func record(distance: Double) {
        furthestDistanceMeters = max(furthestDistanceMeters, distance)
        defer { lastMatchedDistance = distance }
        guard let last = lastMatchedDistance,
              last != distance,
              abs(distance - last) <= TrailWalkPolicy.gapBoundMeters
        else { return }
        insert(min(last, distance), max(last, distance))
    }

    /// The union's total length, in metres.
    var coveredMeters: Double {
        ranges.reduce(0) { total, range in total + (range.upperBound - range.lowerBound) }
    }

    var ranges: [ClosedRange<Double>] {
        stride(from: 0, to: intervals.count - 1, by: 2).map { pair in
            intervals[pair]...intervals[pair + 1]
        }
    }

    /// Covered length over the route's, clamped to 0…1 with the same
    /// arithmetic `RouteProfile.fractionComplete(atDistance:)` and
    /// `SharedTrailSnapshot.fractionComplete` share. `nil` for a route with
    /// no length, where a percentage would mean nothing.
    func fractionComplete(routeDistanceMeters: Double) -> Double? {
        guard routeDistanceMeters > 0 else { return nil }
        return min(1, max(0, coveredMeters / routeDistanceMeters))
    }

    /// Whether this walk is worth keeping as a record.
    var meetsMinimum: Bool {
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
        for pair in stride(from: 0, to: intervals.count - 1, by: 2) {
            let lower = intervals[pair]
            let upper = intervals[pair + 1]
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
nonisolated struct TrailWalkRecord: Codable, Equatable, Sendable {
    var hikeID: UUID
    var startedAt: Date
    var coverage: TrailWalkCoverage
    /// Active time accrued before ``phaseChangedAt``. The current stretch,
    /// if the walk is following, is added on read — see
    /// ``activeSeconds(at:)``.
    var bankedActiveSeconds: TimeInterval
    /// ``TrailWalkPhase`` by raw value, for the reason every stored enum here
    /// is.
    var phaseID: String
    var phaseChangedAt: Date
    /// When the last on-route match landed, matched or merely seen while
    /// paused. What ``TrailWalkPolicy/abandonAfter`` is measured from.
    var lastMatchedAt: Date?
    /// The route's length *at the time of the walk*: a route re-imported or
    /// edited later must not rewrite history.
    var routeDistanceMeters: Double

    init(hikeID: UUID, routeDistanceMeters: Double, startedAt: Date) {
        self.hikeID = hikeID
        self.routeDistanceMeters = routeDistanceMeters
        self.startedAt = startedAt
        coverage = TrailWalkCoverage()
        bankedActiveSeconds = 0
        phaseID = TrailWalkPhase.following.rawValue
        phaseChangedAt = startedAt
        lastMatchedAt = startedAt
    }

    var phase: TrailWalkPhase {
        get { TrailWalkPhase(rawValue: phaseID) ?? .following }
        set { phaseID = newValue.rawValue }
    }

    /// The clock minus its pauses, read at `now`.
    func activeSeconds(at now: Date) -> TimeInterval {
        guard phase == .following else { return bankedActiveSeconds }
        return bankedActiveSeconds + max(0, now.timeIntervalSince(phaseChangedAt))
    }

    /// The moment the walk was last known to be on the route, for the
    /// abandonment rules.
    var lastActivityAt: Date { lastMatchedAt ?? startedAt }

    mutating func pause(at now: Date) {
        guard phase == .following else { return }
        bankedActiveSeconds = activeSeconds(at: now)
        phase = .paused
        phaseChangedAt = now
    }

    mutating func resume(at now: Date) {
        guard phase == .paused else { return }
        phase = .following
        phaseChangedAt = now
    }

    var coveredFraction: Double {
        coverage.fractionComplete(routeDistanceMeters: routeDistanceMeters) ?? 0
    }

    /// Whether a match `distance` metres along the route is the walk
    /// reaching the end.
    func reachesEnd(atMatch distance: Double) -> Bool {
        TrailWalkPolicy.hasReachedEnd(
            coveredFraction: coveredFraction,
            distanceToEndMeters: max(0, routeDistanceMeters - distance)
        )
    }

    /// Whether the walk has gone unmatched for long enough to count as
    /// abandoned.
    func isAbandoned(at now: Date) -> Bool {
        now.timeIntervalSince(lastActivityAt) > TrailWalkPolicy.abandonAfter
    }

    /// Whether a walk found still open at launch is too old to adopt.
    func isStale(at now: Date) -> Bool {
        now.timeIntervalSince(lastActivityAt) > TrailWalkPolicy.staleAtLaunchAfter
    }
}
