//
//  WatchRouteTracker.swift
//  OpenHikesShared
//
//  Where along a trail somebody is standing, worked out on the watch.
//
//  ## Why the watch matches for itself
//
//  Because the phone is in a pocket under a waterproof and may be out of
//  Bluetooth range, and a follow that stopped whenever the link did would be a
//  follow that stopped on exactly the walks this exists for. The watch has its
//  own receiver and, once ``WatchTrailPackage`` has crossed, its own line; it
//  needs nothing further from the phone to answer where on that line a fix
//  fell.
//
//  ## What this is not
//
//  It is not `TrailMatcher`, and the difference is the *graph*. The phone
//  matches a fix against every way in the area, routes between matches through
//  a corridor, and reasons about which trail somebody turned onto — work that
//  needs Overpass, an edge index and a recording's history. This has one
//  polyline and one question about it. Nothing here should grow toward the
//  other: a watch that disagreed with the phone about which trail a hiker is
//  on would be worse than a watch that only ever spoke about the one it was
//  handed.
//
//  ## The out-and-back, which is the case that bites
//
//  A plain nearest-point scan is wrong on a route that comes back along
//  itself: the two legs are the same ground, so a fix on the return leg sits
//  exactly as near the outbound one, and the reported distance-along flips
//  between them fix by fix. Continuity alone does not settle it either, and
//  that is worth saying plainly because it is the obvious fix and it does not
//  work: an out-and-back is *symmetric about its turn*, so the two candidates
//  are equidistant from the last match as well as from the hiker.
//
//  What settles it is the hiker's own direction, which is what `RouteProfile`
//  uses and which `CLLocation.course` reports on a watch as well as on a
//  phone. The rule here is the app's, with the same two constants: among the
//  candidates that are tied on distance from the line, prefer the ones running
//  *with* the hiker, and among those the one nearest the last match. A fix
//  with no course to offer — a stationary receiver reports −1 — falls back to
//  continuity, and then to the first candidate, which is the reading a hiker
//  who has just opened the app should get.
//
//  ## Scale
//
//  Distances are measured along the *decimated* line the watch was sent and
//  reported on the *trail's* scale — see ``WatchTrailPackage/totalDistanceMeters``.
//  Dropping points shortens a line, so the two differ, and a hiker must not be
//  told a trail is shorter than the phone says it is.
//

import Foundation

/// Where along a trail a fix fell, and how far off it.
public struct WatchRouteTracker: Sendable, Equatable {
    /// How far off the line a fix may be and still count as on the trail.
    ///
    /// The same 75 m `RouteProfile.followMatchThresholdMeters` uses, and
    /// deliberately the same number rather than a watch-sized one: a hiker
    /// looking at a phone and a watch on the same walk must not be told they
    /// are on the trail by one and off it by the other.
    public static let matchThresholdMeters: Double = 75

    /// How far along the line, either side of the last match, a fix is
    /// searched before the whole trail is considered.
    ///
    /// `RouteProfile.continuitySearchRadiusMeters` is 1000 m and this is the
    /// same figure for the same reason: a hiker covers a couple of metres
    /// between fixes, so it is orders of magnitude more slack than walking
    /// needs, sized to absorb a run of rejected fixes or a screen that was
    /// asleep rather than ordinary movement.
    public static let continuityWindowMeters: Double = 1000

    /// How much further from the line a candidate may sit and still count as
    /// tied with the closest one, and so be eligible for the course and
    /// continuity tie-breaks. `RouteProfile.tieBreakToleranceMeters`, for the
    /// reason it gives: wide enough to cover the two legs of an out-and-back
    /// sampled a few metres apart, narrow enough that genuinely different
    /// ground is not a contender.
    public static let tieBreakToleranceMeters: Double = 20

    /// How far a segment's direction may differ from the hiker's own course
    /// and still count as the way they are going.
    /// `RouteProfile.courseAgreementDegrees`, and the same 90°: the two legs
    /// of an out-and-back are 180° apart, so this survives a great deal of
    /// noise in either the reported course or the individual segment.
    public static let courseAgreementDegrees: Double = 90

    /// How close two candidates' distances from the last match must be before
    /// continuity is treated as having nothing to say.
    ///
    /// A metre, and it exists because the case it settles is *exactly* tied.
    /// An out-and-back is symmetric about its turn, so once the anchor is
    /// there the outbound and return candidates are equidistant to within
    /// floating-point noise, and a plain `<` picks whichever way the last ulp
    /// fell — the same fix reading as 25% or 75% complete depending on
    /// rounding. Below this the scan's own order decides instead, which is
    /// deterministic and under-reports progress rather than claiming a hiker
    /// is nearly home.
    public static let continuityTieMeters: Double = 1

    /// What one fix resolved to.
    public struct Position: Equatable, Sendable {
        /// How far along the trail, on the trail's own scale.
        public var distanceAlongRouteMeters: Double
        /// What is left of the trail ahead.
        public var remainingMeters: Double
        /// `0...1` along the trail.
        public var fractionComplete: Double
        /// How far the fix fell from the line, whether or not that was close
        /// enough to count.
        ///
        /// Reported for the unmatched case too, which is the point: a hiker
        /// who has walked off a trail is better served by "180 m off" than by
        /// a screen that simply stops saying anything.
        public var offRouteMeters: Double
        /// The *trail's* height where the fix was matched, not the altitude
        /// the receiver reported. The same choice `SharedTrailSnapshot.LiveFix`
        /// makes, so the two agree: GPS vertical noise is not a trail's
        /// elevation.
        public var trailElevationMeters: Double?
        /// Whether the fix was inside ``matchThresholdMeters``.
        public var isOnTrail: Bool
    }

    private let points: [WatchTrailPoint]
    /// Cumulative metres along the decimated line, aligned with `points`.
    private let lineDistances: [Double]
    /// Trail metres per line metre. See this file's header.
    private let scale: Double
    private let totalDistanceMeters: Double
    /// Where the last accepted match landed, in *line* metres. `nil` until
    /// there has been one, which is what makes the first fix a whole-line
    /// search.
    private var anchorLineDistance: Double?

    public init(_ package: WatchTrailPackage) {
        points = package.points
        var cumulative: [Double] = []
        cumulative.reserveCapacity(package.points.count)
        var running = 0.0
        var previous: WatchTrailPoint?
        for point in package.points {
            if let previous {
                running += WatchGeodesy.distanceMeters(
                    fromLatitude: previous.latitude,
                    longitude: previous.longitude,
                    toLatitude: point.latitude,
                    longitude: point.longitude
                )
            }
            cumulative.append(running)
            previous = point
        }
        lineDistances = cumulative
        // A package claiming no length is degenerate — the phone sends
        // `Hike.distanceMeters`, which is measured from the route — but it
        // must not make every reading below collapse to zero, which is what
        // clamping to a zero total would do. The line's own length is what
        // "as measured" means, and the scale is then 1.
        totalDistanceMeters = package.totalDistanceMeters > 0
            ? package.totalDistanceMeters
            : running
        scale = running > 0 && package.totalDistanceMeters > 0
            ? package.totalDistanceMeters / running
            : 1
    }

    /// The trail's length, on the trail's own scale.
    public var trailLengthMeters: Double { totalDistanceMeters }

    /// Whether this tracker has a line to match against at all.
    public var isUsable: Bool { points.count > 1 }

    /// Forgets where the hiker was, so the next fix is searched against the
    /// whole trail.
    ///
    /// What a resumed walk wants: the stretch between a pause and a resume is
    /// unobserved by construction, and it can be longer than the continuity
    /// window — a hiker who paused at a saddle and resumed at the hut has
    /// moved further than any run of rejected fixes ever would.
    public mutating func forgetPosition() { anchorLineDistance = nil }

    /// Matches a fix, advancing the continuity anchor if it landed on the
    /// trail.
    ///
    /// - Parameter courseDegrees: the direction the hiker is travelling in,
    ///   clockwise from north. `nil` for a fix that does not carry one —
    ///   `CLLocation.course` is negative when the receiver cannot say, and a
    ///   stationary hiker is exactly when it cannot. Passing the negative
    ///   value through as a bearing would point the hiker due north and make
    ///   the tie-break worse than having none.
    ///
    /// `nil` only when there is no line to match against, which is a trail
    /// with nothing to measure rather than a hiker who has left one.
    public mutating func advance(
        latitude: Double,
        longitude: Double,
        courseDegrees: Double? = nil
    ) -> Position? {
        guard let match = nearest(
            latitude: latitude,
            longitude: longitude,
            courseDegrees: courseDegrees
        ) else { return nil }
        let isOnTrail = match.offRouteMeters <= Self.matchThresholdMeters
        if isOnTrail { anchorLineDistance = match.lineDistance }
        let alongTrail = min(max(match.lineDistance * scale, 0), totalDistanceMeters)
        return Position(
            distanceAlongRouteMeters: alongTrail,
            remainingMeters: max(0, totalDistanceMeters - alongTrail),
            fractionComplete: totalDistanceMeters > 0
                ? min(1, max(0, alongTrail / totalDistanceMeters))
                : 0,
            offRouteMeters: match.offRouteMeters,
            trailElevationMeters: match.elevationMeters,
            isOnTrail: isOnTrail
        )
    }

    private struct Candidate {
        var lineDistance: Double
        var offRouteMeters: Double
        var elevationMeters: Double?
        /// Whether this leg runs the way the hiker is going. `false` when
        /// there was no course to compare with, which makes it a tie-break
        /// nobody wins rather than one everybody does.
        var runsWithTheHiker: Bool
    }

    /// The closest point on the line, preferring the continuity window.
    ///
    /// Two passes at worst, and the second is only reached when the hiker is
    /// genuinely nowhere near where they were. Each pass is a few hundred
    /// segments of tangent-plane arithmetic against a fix that arrives about
    /// once a second, which is nothing on this hardware — and a segment grid
    /// of the kind `TrailMatcherGraphIndex` keeps would be structure to
    /// maintain for a line that never changes.
    private func nearest(
        latitude: Double,
        longitude: Double,
        courseDegrees: Double?
    ) -> Candidate? {
        if let anchor = anchorLineDistance,
           let windowed = scan(
               latitude: latitude,
               longitude: longitude,
               courseDegrees: courseDegrees,
               within: (anchor - Self.continuityWindowMeters)...(anchor + Self.continuityWindowMeters)
           ),
           windowed.offRouteMeters <= Self.matchThresholdMeters {
            return windowed
        }
        return scan(
            latitude: latitude,
            longitude: longitude,
            courseDegrees: courseDegrees,
            within: nil
        )
    }

    private func scan(
        latitude: Double,
        longitude: Double,
        courseDegrees: Double?,
        within window: ClosedRange<Double>?
    ) -> Candidate? {
        guard points.count > 1 else { return nil }
        var closest = Double.infinity
        var contenders: [Candidate] = []
        for index in 0..<(points.count - 1) {
            if let window,
               lineDistances[index + 1] < window.lowerBound
                   || lineDistances[index] > window.upperBound { continue }
            let start = points[index]
            let end = points[index + 1]
            let projection = WatchGeodesy.project(
                latitude: latitude,
                longitude: longitude,
                onSegmentFromLatitude: start.latitude,
                longitude: start.longitude,
                toLatitude: end.latitude,
                longitude: end.longitude
            )
            // Everything further from the line than the best so far, by more
            // than the tolerance, can never win a tie-break either — so it is
            // dropped here rather than collected and sorted.
            guard projection.offRouteMeters <= closest + Self.tieBreakToleranceMeters else { continue }
            closest = min(closest, projection.offRouteMeters)
            let segmentLength = lineDistances[index + 1] - lineDistances[index]
            contenders.append(
                Candidate(
                    lineDistance: lineDistances[index] + segmentLength * projection.fraction,
                    offRouteMeters: projection.offRouteMeters,
                    elevationMeters: elevation(from: start, to: end, fraction: projection.fraction),
                    runsWithTheHiker: runsWithTheHiker(projection, courseDegrees: courseDegrees)
                )
            )
        }
        // The running `closest` improved as the scan went, so the early
        // contenders were kept against a weaker bar than the late ones. This
        // is where they are all measured against the final one.
        contenders.removeAll { $0.offRouteMeters > closest + Self.tieBreakToleranceMeters }
        return preferred(among: contenders)
    }

    /// The winner among candidates that are all as near the line as each
    /// other: the hiker's direction first, then continuity, then the one the
    /// scan met first.
    private func preferred(among contenders: [Candidate]) -> Candidate? {
        guard contenders.count > 1 else { return contenders.first }
        let agreeing = contenders.filter(\.runsWithTheHiker)
        let shortlist = agreeing.isEmpty ? contenders : agreeing
        guard let anchor = anchorLineDistance else { return shortlist.first }
        return shortlist.min { lhs, rhs in
            let left = abs(lhs.lineDistance - anchor)
            let right = abs(rhs.lineDistance - anchor)
            // `min(by:)` keeps what it already has when this says no, so an
            // answer of "too close to call" is the earlier candidate. See
            // ``continuityTieMeters``.
            guard abs(left - right) > Self.continuityTieMeters else { return false }
            return left < right
        }
    }

    /// Whether a segment runs the way the hiker is going.
    private func runsWithTheHiker(
        _ projection: WatchGeodesy.SegmentProjection,
        courseDegrees: Double?
    ) -> Bool {
        guard let courseDegrees, courseDegrees.isFinite, courseDegrees >= 0,
              projection.dx != 0 || projection.dy != 0 else { return false }
        var difference = abs(projection.bearingDegrees - courseDegrees)
            .truncatingRemainder(dividingBy: 360)
        if difference > 180 { difference = 360 - difference }
        return difference <= Self.courseAgreementDegrees
    }

    /// The trail's height at a point part-way along a segment.
    ///
    /// Interpolated when both ends carry one, and otherwise whichever end
    /// does — a route whose elevations are partial is ordinary in imported
    /// GPX, and the nearer known height is a better answer than no height at
    /// all on a screen whose whole job is to say where the climbing is.
    private func elevation(
        from start: WatchTrailPoint,
        to end: WatchTrailPoint,
        fraction: Double
    ) -> Double? {
        switch (start.elevationMeters, end.elevationMeters) {
        case let (low?, high?): low + (high - low) * fraction
        case let (low?, nil): low
        case let (nil, high?): high
        case (nil, nil): nil
        }
    }
}
