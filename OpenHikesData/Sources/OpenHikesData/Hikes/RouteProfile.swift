//
//  RouteProfile.swift
//  OpenHikes
//
//  Precomputed distance/elevation index for a route. Built once (O(n)) so that
//  scrubbing the elevation chart resolves a map location in O(log n) via binary
//  search — no per-drag recomputation.
//

import Algorithms
import CoreLocation
import Foundation
import OpenHikesShared

nonisolated public struct RouteProfile: Sendable {
    /// How far off the route (in meters) a GPS fix can be and still count as
    /// "on the trail" — shared by every consumer of
    /// `nearestPoint(to:near:heading:headingOverridesReference:scope:)` (in-app auto-follow, the
    /// foreground widget feed) and of `nearestPointHeadingFirst(to:near:heading:)` (the background
    /// one) so they all agree on the same trail.
    public static let followMatchThresholdMeters: Double = 75

    /// How far a segment's direction may differ from the hiker's own course
    /// and still count as the way they are going.
    ///
    /// Less a tolerance than the question itself: does this leg of the trail
    /// run *with* the hiker, or against them? The two legs of an out-and-back
    /// are 180° apart, so at 90° the answer survives a great deal of noise in
    /// either the reported course or the individual segment — which is the
    /// point, since a trail's own bearing wanders segment to segment while the
    /// leg it belongs to does not.
    public static let courseAgreementDegrees: Double = 90
    /// How much farther off-route a segment may project and still be treated
    /// as tied with the closest one, and therefore be eligible for the
    /// course/continuity tie-break. Wide enough to cover the two legs of an
    /// out-and-back sampled a few metres apart, narrow enough that a genuinely
    /// different trail is not a contender.
    public static let tieBreakToleranceMeters = 20.0
    /// How far along the route, either side of the last match, a fix is
    /// searched before the whole route is considered. A hiker covers a couple
    /// of metres between fixes, so this is orders of magnitude more slack than
    /// continuous walking needs; it is sized to absorb a run of rejected fixes
    /// or a backgrounded app, not ordinary movement.
    public static let continuitySearchRadiusMeters = 1000.0

    /// How much of the route a fix may be searched against when the continuity
    /// window holds nothing on-route.
    public enum SearchScope: Sendable {
        /// Fall back to the rest of the route. The hiker may have reopened
        /// the app somewhere else entirely.
        case wholeRoute
        /// Stay inside the window around the last match. Live follow latches
        /// on to this once a widened scan has already come up empty — see
        /// ``OffRouteSearchPolicy``.
        case continuityWindow
    }

    /// Upper bound on how many points the elevation chart is asked to draw.
    /// One plotted point per two device pixels is already past what a 390 pt
    /// chart resolves at 3×; beyond that, every extra sample is main-thread
    /// cost at drag frequency with no picture to go with it.
    public static let plottedSampleBudget = 500

    /// All route coordinates, in order.
    public let coordinates: [CLLocationCoordinate2D]
    /// Cumulative metres from the start, aligned with `coordinates`, ascending.
    ///
    /// Walked metres: a leg a pause opened adds nothing (see
    /// ``RouteBoundary``), so the point a recording resumed on stands at the
    /// same distance as the one before the pause, and the axis — progress,
    /// what is left, the chart — measures the walk rather than the drive
    /// between its pieces.
    public let distances: [Double]
    /// Points that carry elevation, for charting — downsampled to
    /// ``plottedSampleBudget`` on long routes. See ``downsampledForDrawing(_:)``
    /// for what that keeps; in particular the route's true high and low points
    /// always survive, so ``elevationRange`` is exact however long the track is.
    public let samples: [ElevationSample]
    /// Where along the route the recording was paused, in metres from the
    /// start: where the two recorded pieces meet, since the leg between them
    /// has no length. One entry per distinct distance, in order — two pauses
    /// with a single fix between them meet at one place, and the chart draws
    /// one rule there.
    ///
    /// Kept as distances rather than as indices because that is the axis the
    /// elevation chart is drawn against, and bounded by the number of times
    /// the hiker reached for the pause button rather than by the length of
    /// the walk. See ``RouteBoundary``.
    public let pauseDistances: [Double]
    /// What the route's *undownsampled* elevations add up to.
    ///
    /// Distinct from ``elevationRange``, which is derived from the plotted
    /// samples and is the right answer for the chart's y-scale — the chart
    /// must be scaled to what it draws. This is the right answer for anything
    /// describing the trail itself, and it is the only source of the climb and
    /// descent totals, which a downsampled series cannot produce: dropping
    /// points removes the little rises they spanned.
    public let elevation: RouteElevationSummary

    private let sampleDistances: [Double]
    /// The segments a pause opened, by the index of the point they leave —
    /// `coordinates[i]` to `coordinates[i + 1]`. Never matched against: see
    /// ``RouteBoundary``. Bounded by the number of pauses.
    let pausedSegments: Set<Int>

    public init(route: [RouteCoordinate]) {
        self = Self.build(
            route: route,
            onPoint: { _, _ in /* nothing else needs the walk */ },
            shouldContinue: { true }
        )
    }

    /// - Parameter onPoint: called once per route point, in order, with the
    ///   length of the leg arriving at it — 0 for the first point and for a
    ///   point a pause ended, by ``RouteCoordinate/legMeters(from:)``. The walk below
    ///   computes those distances to build ``distances``, so a caller that
    ///   needs them for something else — ``HikeDetailPreparation`` building
    ///   ``HikeRouteStatistics`` — can take them from here rather than walking
    ///   the route a second time to recompute the same trigonometry.
    ///
    ///   Not called for the points after a cancellation, since this throws
    ///   rather than returning a partial profile.
    public static func cancellable(
        route: [RouteCoordinate],
        onPoint: (RouteCoordinate, Double) -> Void = { _, _ in /* no-op default */ }
    ) throws(CancellationError) -> Self {
        let profile = Self.build(route: route, onPoint: onPoint) {
            !Task.isCancelled
        }
        guard !Task.isCancelled else { throw CancellationError() }
        return profile
    }

    private init(
        coordinates: [CLLocationCoordinate2D],
        distances: [Double],
        samples: [ElevationSample],
        pauseDistances: [Double],
        pausedSegments: Set<Int>,
        elevation: RouteElevationSummary
    ) {
        self.coordinates = coordinates
        self.distances = distances
        self.samples = samples
        self.pauseDistances = pauseDistances
        self.pausedSegments = pausedSegments
        self.elevation = elevation
        sampleDistances = samples.map(\.distanceMeters)
    }

    private static func build(
        route: [RouteCoordinate],
        onPoint: (RouteCoordinate, Double) -> Void,
        shouldContinue: () -> Bool
    ) -> Self {
        var routeCoordinates: [CLLocationCoordinate2D] = []
        var routeDistances: [Double] = []
        var routeSamples: [ElevationSample] = []
        var routePauseDistances: [Double] = []
        var routePausedSegments: Set<Int> = []
        var elevations = ElevationAccumulator()
        routeCoordinates.reserveCapacity(route.count)
        routeDistances.reserveCapacity(route.count)

        var cumulative = 0.0
        var previous: RouteCoordinate?
        for (index, point) in route.enumerated() {
            if index.isMultiple(of: 255), !shouldContinue() { break }
            let coordinate = point.clCoordinate
            // A paused leg is no distance — see ``RouteBoundary``.
            let segment = previous.map(point.legMeters(from:)) ?? 0
            cumulative += segment
            previous = point
            routeCoordinates.append(coordinate)
            routeDistances.append(cumulative)
            // `index > 0` for the reason ``[RouteCoordinate]/pausedSegments``
            // starts at 1: a boundary describes the leg arriving at a point,
            // and the first point of a route arrives from nowhere.
            let resumes = index > 0 && point.isPauseBoundary
            if resumes {
                routePausedSegments.insert(index - 1)
                if routePauseDistances.last != cumulative {
                    routePauseDistances.append(cumulative)
                }
            }
            elevations.record(point)
            // `isFinite`, and here rather than in each consumer: a height that
            // is not a number is not a height, and admitted into `samples` it
            // goes wrong differently in every place that reads them. The
            // downsampling buckets below seed their bounds with the bucket's
            // first sample and displace them by comparison, and every
            // comparison against a NaN is false — so a poisoned first sample
            // keeps both bounds and the bucket contributes it *instead of* the
            // summit that was walked. `ElevationChartView`'s `==` compares the
            // sample arrays to decide whether to rebuild its body, and
            // `nan != nan`, so for such a hike it can never hold and the body
            // is rebuilt at drag frequency for a picture that has not changed.
            // The accumulator above already refuses the same value, for the
            // same reason; `GPXImport` refuses it at the door, and this is
            // what covers hikes stored before it did.
            if let pointElevation = point.elevation, pointElevation.isFinite {
                Self.append(
                    ElevationSample(distanceMeters: cumulative, elevation: pointElevation, resumesAfterPause: resumes),
                    to: &routeSamples,
                    mergingRepeats: false
                )
            }
            onPoint(point, segment)
        }

        let plotted = Self.downsampledForDrawing(routeSamples)
        return Self(
            coordinates: routeCoordinates,
            distances: routeDistances,
            samples: plotted,
            pauseDistances: routePauseDistances,
            pausedSegments: routePausedSegments,
            elevation: RouteElevationSummary(elevations)
        )
    }

    /// Adds `sample` to a series in route order, keeping at most one pair of
    /// samples at any distance: the step at a pause.
    ///
    /// The fix before a pause and the fix after it stand at the same distance
    /// (the paused leg has no length), and both heights are kept, because the
    /// chart's step between them is the pause. Any other sample at the
    /// distance of a pause's resume folds into it — the run it starts is the
    /// same, and a second resumed sample at one distance would share its
    /// identity. `mergingRepeats` folds the remaining case too, two plain
    /// samples at one distance, which only the downsampled series does; an
    /// undownsampled route draws every point it has.
    private static func append(
        _ sample: ElevationSample,
        to series: inout [ElevationSample],
        mergingRepeats: Bool
    ) {
        guard let last = series.last, sample.distanceMeters <= last.distanceMeters else {
            series.append(sample)
            return
        }
        if sample.resumesAfterPause, !last.resumesAfterPause {
            series.append(sample)
        } else if last.resumesAfterPause || sample.resumesAfterPause || mergingRepeats {
            series[series.count - 1] = ElevationSample(
                distanceMeters: sample.distanceMeters,
                elevation: sample.elevation,
                resumesAfterPause: last.resumesAfterPause || sample.resumesAfterPause
            )
        } else {
            series.append(sample)
        }
    }

    /// Thins the elevation samples down to ``plottedSampleBudget`` for drawing,
    /// keeping the shape of the trail rather than a sparse sketch of it.
    ///
    /// A plain stride would break the chart in two silent ways, because the
    /// chart derives its axes from whatever is plotted: stepping over the
    /// summit shrinks `elevationRange` and the drawn line runs off the top of
    /// its own y-scale, and dropping the final sample shortens the x-scale
    /// while the live tracker is still placed from `distances`, putting the
    /// hiker's own position past the end of the graph near the finish.
    ///
    /// So instead: keep the first and last samples outright, split the rest
    /// into equal buckets, and emit each bucket's lowest and highest point in
    /// route order. That preserves the envelope, and with it every local peak
    /// and trough the eye actually reads — including the global extremes,
    /// which are by definition their own bucket's min or max.
    ///
    /// Routes at or under the budget are returned untouched: a six-point walk
    /// draws its six real points.
    private static func downsampledForDrawing(_ samples: [ElevationSample]) -> [ElevationSample] {
        // Two per bucket, plus the reserved first and last.
        let bucketCount = (plottedSampleBudget - 2) / 2
        guard samples.count > plottedSampleBudget, bucketCount > 0 else { return samples }

        let last = samples.count - 1
        var picked: [Int] = [0]
        picked.reserveCapacity(plottedSampleBudget)

        // Interior only — the endpoints are already spoken for.
        let interiorCount = last - 1
        for bucket in 0..<bucketCount {
            let start = 1 + interiorCount * bucket / bucketCount
            let end = 1 + interiorCount * (bucket + 1) / bucketCount
            guard start < end else { continue }

            var lowest = start
            var highest = start
            for index in start..<end {
                if samples[index].elevation < samples[lowest].elevation {
                    lowest = index
                }
                if samples[index].elevation > samples[highest].elevation {
                    highest = index
                }
            }
            if lowest == highest {
                picked.append(lowest)
            } else {
                picked.append(min(lowest, highest))
                picked.append(max(lowest, highest))
            }
        }
        picked.append(last)

        // Distances are cumulative, so they never decrease — but a stationary
        // stretch can repeat one, and `Charts` plots (and `ElevationSample`
        // identifies) by distance. Keep the later point of any such pair so the
        // series stays ascending without losing the route's end; only a
        // pause's step keeps two (see ``append(_:to:mergingRepeats:)``).
        //
        // A pause whose resumed sample was not picked still ends the climb's
        // run: it is carried to the next sample that was, which is the first
        // plotted one past the pause.
        var plotted: [ElevationSample] = []
        plotted.reserveCapacity(picked.count)
        var previousIndex = -1
        for index in picked {
            let sample = samples[index]
            let resumes = samples[(previousIndex + 1)...index].contains(where: \.resumesAfterPause)
            previousIndex = index
            append(
                ElevationSample(
                    distanceMeters: sample.distanceMeters,
                    elevation: sample.elevation,
                    resumesAfterPause: resumes
                ),
                to: &plotted,
                mergingRepeats: true
            )
        }
        return plotted
    }

    /// Elevation min…max across the plotted samples, if any.
    ///
    /// The filter is a backstop now rather than the guard it used to be:
    /// ``build(route:onPoint:shouldContinue:)`` no longer admits a non-finite
    /// height into ``samples`` at all. It stays because of what its absence
    /// would cost if some future path did. Every comparison against a NaN is
    /// false, so `minAndMax()` never displaces a bound it has already seeded
    /// with one: a NaN *first* comes back as the min, a NaN *last* as the max.
    /// Either way the range is built from a bound that isn't ordered, and
    /// `ClosedRange` traps on that the moment the chart asks for its y-domain
    /// — a crash, rather than an axis that merely looks wrong.
    public var elevationRange: ClosedRange<Double>? {
        guard let bounds = samples.lazy.map(\.elevation).filter(\.isFinite).minAndMax() else {
            return nil
        }
        return bounds.min...bounds.max
    }

    /// The route's full length in metres — the denominator behind every
    /// progress readout.
    public var totalDistanceMeters: Double { distances.last ?? 0 }

    /// How far along the route a distance is, as a fraction of the whole,
    /// clamped to 0…1. `nil` for a route with no length, where a percentage
    /// would mean nothing.
    ///
    /// Deliberately the same arithmetic as `SharedTrailSnapshot.fractionComplete`,
    /// which the widget reads: both clamp a matched distance-along-route over
    /// the route's total the same way, so the app and the widget can't turn one
    /// position into two different percentages.
    public func fractionComplete(atDistance distance: Double) -> Double? {
        let total = totalDistanceMeters
        guard total > 0 else { return nil }
        return min(1, max(0, distance / total))
    }

    /// Distance still to walk from a position along the route, in metres.
    public func remainingDistanceMeters(atDistance distance: Double) -> Double {
        max(0, totalDistanceMeters - distance)
    }

    /// Map coordinate at a distance along the route, interpolated within the
    /// bracketing segment. O(log n).
    ///
    /// Past the end it is the *first* point at the last distance, not the
    /// last point. They are one place unless the route ends on a pause, and
    /// then the lone fix after it stands at the same distance as the one
    /// before it: the end is a join, and a join reads as the fix before the
    /// pause (see ``RouteBoundary``).
    public func coordinate(atDistance target: Double) -> CLLocationCoordinate2D? {
        guard let firstDistance = distances.first, let lastDistance = distances.last,
              let firstCoordinate = coordinates.first
        else { return nil }
        if target <= firstDistance { return firstCoordinate }
        if target >= lastDistance { return coordinates[distances.partitioningIndex { $0 >= lastDistance }] }

        let upper = distances.partitioningIndex { $0 >= target }
        let lower = upper - 1
        let segmentLength = distances[upper] - distances[lower]
        guard segmentLength > 0 else { return coordinates[upper] }
        let fraction = (target - distances[lower]) / segmentLength
        return RouteGeometry.interpolate(
            from: coordinates[lower],
            to: coordinates[upper],
            fraction: fraction
        )
    }

    /// Elevation sample nearest to a distance along the route. O(log n).
    public func sample(atDistance target: Double) -> ElevationSample? {
        nearestIndex(in: sampleDistances, to: target).map { samples[$0] }
    }

}

// MARK: - Matching a live fix onto the route

/// Split out of the main declaration: this is the GPS-matching half of the
/// profile, used only by the live-follow and background-tracking paths, and it
/// reads independently of the distance/elevation index above.
nonisolated extension RouteProfile {
    /// Projects an arbitrary coordinate (e.g. a live GPS fix) onto the route,
    /// used to auto-follow the elevation graph. Returns the distance-along-route
    /// of the nearest point on any route segment and how far off the route
    /// that point is, in meters — callers use the latter to decide whether the
    /// fix is actually near the trail. O(n): fine at the at-most-one-a-second
    /// rate ``LocationManager/fixes`` publishes at.
    ///
    /// A leg a pause opened is never a candidate (see ``RouteBoundary``), so a
    /// fix on the ground a recording drove across is as far off the route as
    /// the nearest recorded piece — and a route with no other leg, which is
    /// the only route that leaves nothing to project onto, answers `nil`.
    ///
    /// `referenceDistance`, when given (the previous match), breaks ties in
    /// favor of continuity. Loops, out-and-backs, and switchbacks can bring
    /// two very different points along the route within GPS-noise distance of
    /// each other (e.g. a loop's start and finish); without this, ordinary
    /// jitter can flip the match between them — jumping the tracker across
    /// most of the route with no real movement.
    ///
    /// With no reference — the first fix after a hike is selected — ties are
    /// broken toward the *start* of the route instead. There is no continuity
    /// to preserve yet, and on a trail that returns along its outbound leg
    /// every point has a twin that projects just as well, so the raw closest
    /// segment is decided by nothing more than which of two overlapping legs
    /// the GPX happened to sample a fraction of a metre nearer. That coin
    /// flip put a hiker who had just set off at the *finish* of the trail
    /// about half the time — and because the match then becomes the continuity
    /// reference for every later fix, it stayed there for the whole hike.
    /// Preferring the earliest of the tied candidates starts them at the
    /// trailhead, and continuity carries them forward from there.
    ///
    /// `heading` — the hiker's course over ground, when the fix carries one
    /// worth trusting (see ``LocationFixPolicy/course(of:)``) — settles that
    /// question outright, and outranks the assumption about the start. The two
    /// legs of an out-and-back run in opposite directions, so a hiker already
    /// on the way back is going the *wrong* way for the outbound leg and the
    /// right way for the return one. By default it is consulted only when there
    /// is no `referenceDistance`: once a match exists, continuity is the better
    /// evidence, and letting a noisy course overrule it on a single fix would
    /// reintroduce exactly the jumping this parameter set out to stop — a
    /// hiker pausing to look back down the trail is not a hiker who has turned
    /// around.
    ///
    /// `headingOverridesReference` lets the course settle a tie even though a
    /// `referenceDistance` exists. A caller does not pass it on every fix —
    /// that is the jumping described above — but asks for it as a second
    /// opinion, and moves to its answer only once the course has kept
    /// disagreeing with continuity (see `FollowAnchor`). Without it, a hiker
    /// walking home along an out-and-back is held on the outbound leg by
    /// continuity for the whole return. A feed too sparse for that kind of
    /// patience asks ``nearestPointHeadingFirst(to:near:heading:)`` instead.
    ///
    /// A loop's junction stays ambiguous under this test, correctly: both
    /// passes run the same way, so the start assumption still decides it.
    public func nearestPoint(
        to coordinate: CLLocationCoordinate2D,
        near referenceDistance: Double? = nil,
        heading: CLLocationDirection? = nil,
        headingOverridesReference: Bool = false,
        scope: SearchScope = .wholeRoute
    ) -> (distanceAlongRoute: Double, offRouteMeters: Double)? {
        guard !coordinates.isEmpty else { return nil }
        guard coordinates.count > 1 else {
            let only = coordinates[0]
            let offset = RouteGeometry.distanceMeters(from: coordinate, to: only)
            return (0, offset)
        }
        let course = referenceDistance == nil || headingOverridesReference ? heading : nil
        return nearestCandidate(
            to: coordinate,
            near: referenceDistance,
            course: course,
            scope: scope
        )?.match
    }

    /// Projects a fix onto the route letting a usable course outrank
    /// continuity on every fix — the rule the watch's `WatchRouteTracker`
    /// follows — rather than as the second opinion
    /// ``nearestPoint(to:near:heading:headingOverridesReference:scope:)``
    /// offers.
    ///
    /// For the background feed, which is too sparse for the patience
    /// `FollowAnchor` shows in the foreground. Significant-location-change
    /// delivery arrives every five hundred metres or so at best, so waiting
    /// for three fixes to disagree with continuity would hold a hiker on the
    /// wrong leg of an out-and-back for a kilometre and a half — and because
    /// coverage accrues from whatever this answers, a walk home along the
    /// outbound leg's mirror never reaches the end at all.
    ///
    /// Two steps, and the second is what the sparseness costs. The continuity
    /// window around `referenceDistance` is asked first, with the course
    /// settling any tie in it; a winner running the hiker's way is the answer.
    /// Only when it does not is the whole route asked, because one fix can
    /// carry a hiker from the outbound leg in the window to a point on the
    /// return leg outside it. A route-wide winner replaces the windowed one
    /// only when it runs the hiker's way and is itself on the trail, and it
    /// can never be more than ``tieBreakToleranceMeters`` farther off the
    /// route than the window's closest segment, since the whole route's
    /// closest is never farther than the window's. So a genuinely different
    /// trail is no more a contender here than it is anywhere else.
    ///
    /// What it costs is the jumping continuity exists to prevent, bounded to
    /// one fix: a course pointing the wrong way within twenty metres of
    /// another leg moves the match to that leg, and the next fix with an
    /// honest course moves it back. `LocationFixPolicy.course(of:)` already
    /// refuses a course worse than 45°, and the test is a disagreement of 90°
    /// or more. With no course, or no reference to disagree with, this is
    /// ``nearestPoint(to:near:heading:headingOverridesReference:scope:)``
    /// exactly — continuity for a Wi-Fi or cell fix that carries no course,
    /// and for the first fix the course and then the start of the route.
    public func nearestPointHeadingFirst(
        to coordinate: CLLocationCoordinate2D,
        near referenceDistance: Double?,
        heading: CLLocationDirection?
    ) -> (distanceAlongRoute: Double, offRouteMeters: Double)? {
        guard let referenceDistance, let heading, coordinates.count > 1 else {
            return nearestPoint(to: coordinate, near: referenceDistance, heading: heading)
        }
        guard let windowed = nearestCandidate(
            to: coordinate,
            near: referenceDistance,
            course: heading,
            scope: .wholeRoute
        ) else { return nil }
        if Self.runs(windowed, with: heading) { return windowed.match }

        let fullRange = 0..<(coordinates.count - 1)
        var candidates: [NearestCandidate] = []
        candidates.reserveCapacity(fullRange.count)
        var best: NearestCandidate?
        appendCandidates(to: coordinate, in: fullRange, candidates: &candidates, best: &best)
        guard let best else { return windowed.match }
        let routeWide = breakTie(
            among: candidates,
            best: best,
            anchor: referenceDistance,
            course: heading
        )
        guard Self.runs(routeWide, with: heading),
              routeWide.offRouteMeters <= Self.followMatchThresholdMeters else {
            return windowed.match
        }
        return routeWide.match
    }

    /// The search both matchers share, on a route of at least two points,
    /// returning the winning projection whole so a caller can ask which way
    /// its segment runs. `course` is the one the tie-break consults, already
    /// decided — `nil` when the caller wants continuity alone.
    private func nearestCandidate(
        to coordinate: CLLocationCoordinate2D,
        near referenceDistance: Double?,
        course: CLLocationDirection?,
        scope: SearchScope
    ) -> NearestCandidate? {
        let fullRange = 0..<(coordinates.count - 1)
        let initialRange = referenceDistance.map { reference in
            candidateSegmentRange(near: reference)
        } ?? fullRange
        var candidates: [NearestCandidate] = []
        candidates.reserveCapacity(initialRange.count)
        var best: NearestCandidate?
        appendCandidates(
            to: coordinate,
            in: initialRange,
            candidates: &candidates,
            best: &best
        )

        // An established match normally needs only the nearby route-distance
        // window. If that window no longer contains an on-route candidate, the
        // user may have reopened the app or moved farther than the continuity
        // window, so fall back to the rest of the route once.
        //
        // `scope` is how the caller stops paying for that fallback on every
        // fix: a hiker who has simply stepped off the trail produces an
        // unmatched fix a second, and each one would otherwise re-scan the
        // whole route.
        if scope == .wholeRoute,
           referenceDistance != nil,
           initialRange != fullRange,
           (best?.offRouteMeters ?? .greatestFiniteMagnitude)
               > Self.followMatchThresholdMeters {
            appendCandidates(
                to: coordinate,
                in: fullRange.lowerBound..<initialRange.lowerBound,
                candidates: &candidates,
                best: &best
            )
            appendCandidates(
                to: coordinate,
                in: initialRange.upperBound..<fullRange.upperBound,
                candidates: &candidates,
                best: &best
            )
            candidates.sort { left, right in
                left.distanceAlongRoute < right.distanceAlongRoute
            }
        }
        guard let best else { return nil }

        // Among every segment projection within `tieBreakToleranceMeters` of
        // the closest one, prefer whichever the hiker is actually heading
        // along; failing that (or between two that both qualify), whichever
        // is nearest the anchor.
        return breakTie(
            among: candidates,
            best: best,
            anchor: referenceDistance ?? 0,
            course: course
        )
    }

    /// The segments within ``continuitySearchRadiusMeters`` of
    /// `referenceDistance`, as a half-open segment index range.
    ///
    /// The reference is clamped to the route first: a stale or corrupt anchor
    /// past either end would otherwise produce an empty range, and an empty
    /// range has no candidates to match against at all.
    public func candidateSegmentRange(
        near referenceDistance: Double
    ) -> Range<Int> {
        let segmentCount = max(0, coordinates.count - 1)
        guard segmentCount > 0 else { return 0..<0 }

        let reference = min(max(referenceDistance, 0), totalDistanceMeters)
        let lowerDistance = max(
            0,
            reference - Self.continuitySearchRadiusMeters
        )
        let upperDistance = min(
            totalDistanceMeters,
            reference + Self.continuitySearchRadiusMeters
        )
        let firstPointAtOrAfterLower = distances.partitioningIndex { distance in
            distance >= lowerDistance
        }
        let firstPointAfterUpper = distances.partitioningIndex { distance in
            distance > upperDistance
        }
        let lowerSegment = max(0, firstPointAtOrAfterLower - 1)
        let upperSegment = min(
            segmentCount,
            max(lowerSegment + 1, firstPointAfterUpper)
        )
        return lowerSegment..<upperSegment
    }

    private struct NearestCandidate {
        let distanceAlongRoute: Double
        let offRouteMeters: Double
        let dx: Double
        let dy: Double
        var bearingDegrees: Double { atan2(dx, dy) * 180 / .pi }
        var match: (distanceAlongRoute: Double, offRouteMeters: Double) {
            (distanceAlongRoute, offRouteMeters)
        }
    }

    private func appendCandidates(
        to coordinate: CLLocationCoordinate2D,
        in range: Range<Int>,
        candidates: inout [NearestCandidate],
        best: inout NearestCandidate?
    ) {
        // A paused leg is not trail: the two pieces either side of it are
        // matched, the drive between them never is. See ``RouteBoundary``.
        for index in range where !pausedSegments.contains(index) {
            let projection = RouteGeometry.project(
                coordinate,
                onSegmentFrom: coordinates[index],
                to: coordinates[index + 1]
            )
            var along = distances[index]
                + projection.fraction * (distances[index + 1] - distances[index])
            // The join's own distance reads as the fix *before* the pause —
            // ``coordinate(atDistance:)`` answers that point there — so a fix
            // placed at the very start of a piece a pause began is put just
            // past it, where the axis reads this piece. Otherwise a hiker a
            // few metres short of where the recording resumed would be drawn
            // a drive away, at the other end of the pause.
            if along == distances[index], index > 0, pausedSegments.contains(index - 1) {
                along = along.nextUp
            }
            let candidate = NearestCandidate(
                distanceAlongRoute: along,
                offRouteMeters: projection.offRouteMeters,
                dx: projection.dx,
                dy: projection.dy
            )
            candidates.append(candidate)
            if candidate.offRouteMeters
                < (best?.offRouteMeters ?? .greatestFiniteMagnitude) {
                best = candidate
            }
        }
    }

    private func breakTie(
        among candidates: [NearestCandidate],
        best: NearestCandidate,
        anchor: Double,
        course: CLLocationDirection?
    ) -> NearestCandidate {
        var tied = best
        var tiedRunsWith = Self.runs(best, with: course)
        var bestContinuity = abs(best.distanceAlongRoute - anchor)
        for contender in candidates {
            guard contender.offRouteMeters
                <= best.offRouteMeters + Self.tieBreakToleranceMeters else { continue }
            let contenderRunsWith = Self.runs(contender, with: course)
            if contenderRunsWith != tiedRunsWith {
                guard contenderRunsWith else { continue }
                tied = contender
                tiedRunsWith = true
                bestContinuity = abs(contender.distanceAlongRoute - anchor)
                continue
            }
            let continuity = abs(contender.distanceAlongRoute - anchor)
            if continuity < bestContinuity {
                bestContinuity = continuity
                tied = contender
            }
        }
        return tied
    }

    /// Whether `candidate`'s segment runs the way the hiker is going — never,
    /// when there is no course to ask, nor when it lies square across their
    /// way, as the few metres joining an out-and-back's two legs do.
    private static func runs(
        _ candidate: NearestCandidate,
        with course: CLLocationDirection?
    ) -> Bool {
        guard let course else { return false }
        return RouteGeometry.bearingDifference(course, candidate.bearingDegrees) < courseAgreementDegrees
    }

    /// Index of the value in an ascending array closest to `target`. O(log n).
    ///
    /// The first of several equal values, at the end as everywhere else, for
    /// the reason ``coordinate(atDistance:)`` gives: a route that ends on a
    /// pause ends on a join.
    private func nearestIndex(in sorted: [Double], to target: Double) -> Int? {
        guard let first = sorted.first, let last = sorted.last else { return nil }
        if target <= first { return 0 }
        if target >= last { return sorted.partitioningIndex { $0 >= last } }

        // First index at or past `target`; the endpoints are handled above, so
        // it is always strictly interior and `upper - 1` is always valid.
        let upper = sorted.partitioningIndex { $0 >= target }
        let lower = upper - 1
        return abs(sorted[upper] - target) < abs(sorted[lower] - target) ? upper : lower
    }
}
