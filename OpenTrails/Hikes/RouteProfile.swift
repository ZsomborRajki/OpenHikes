//
//  RouteProfile.swift
//  OpenTrails
//
//  Precomputed distance/elevation index for a route. Built once (O(n)) so that
//  scrubbing the elevation chart resolves a map location in O(log n) via binary
//  search — no per-drag recomputation.
//

import Algorithms
import CoreLocation
import Foundation

nonisolated struct RouteProfile {
    /// How far off the route (in meters) a GPS fix can be and still count as
    /// "on the trail" — shared by every consumer of `nearestPoint(to:near:)`
    /// (in-app auto-follow, the foreground/background widget feeds) so they
    /// all agree on the same trail.
    static let followMatchThresholdMeters: Double = 75

    /// How far a segment's direction may differ from the walker's own course
    /// and still count as the way they are going.
    ///
    /// Less a tolerance than the question itself: does this leg of the trail
    /// run *with* the walker, or against them? The two legs of an out-and-back
    /// are 180° apart, so at 90° the answer survives a great deal of noise in
    /// either the reported course or the individual segment — which is the
    /// point, since a trail's own bearing wanders segment to segment while the
    /// leg it belongs to does not.
    static let courseAgreementDegrees: Double = 90

    /// Upper bound on how many points the elevation chart is asked to draw.
    /// One plotted point per two device pixels is already past what a 390 pt
    /// chart resolves at 3×; beyond that, every extra sample is main-thread
    /// cost at drag frequency with no picture to go with it.
    static let plottedSampleBudget = 500

    /// All route coordinates, in order.
    let coordinates: [CLLocationCoordinate2D]
    /// Cumulative metres from the start, aligned with `coordinates`, ascending.
    let distances: [Double]
    /// Points that carry elevation, for charting — downsampled to
    /// ``plottedSampleBudget`` on long routes. See ``downsampledForDrawing(_:)``
    /// for what that keeps; in particular the route's true high and low points
    /// always survive, so ``elevationRange`` is exact however long the track is.
    let samples: [ElevationSample]

    private let sampleDistances: [Double]

    init(route: [RouteCoordinate]) {
        var routeCoordinates: [CLLocationCoordinate2D] = []
        var routeDistances: [Double] = []
        var routeSamples: [ElevationSample] = []
        routeCoordinates.reserveCapacity(route.count)
        routeDistances.reserveCapacity(route.count)

        var cumulative = 0.0
        var previous: CLLocationCoordinate2D?
        for point in route {
            let coordinate = point.clCoordinate
            if let previous {
                cumulative += RouteGeometry.distanceMeters(from: previous, to: coordinate)
            }
            previous = coordinate
            routeCoordinates.append(coordinate)
            routeDistances.append(cumulative)
            if let elevation = point.elevation {
                routeSamples.append(ElevationSample(distanceMeters: cumulative, elevation: elevation))
            }
        }

        let plotted = Self.downsampledForDrawing(routeSamples)
        coordinates = routeCoordinates
        distances = routeDistances
        samples = plotted
        sampleDistances = plotted.map(\.distanceMeters)
    }

    /// Thins the elevation samples down to ``plottedSampleBudget`` for drawing,
    /// keeping the shape of the trail rather than a sparse sketch of it.
    ///
    /// A plain stride would break the chart in two silent ways, because the
    /// chart derives its axes from whatever is plotted: stepping over the
    /// summit shrinks `elevationRange` and the drawn line runs off the top of
    /// its own y-scale, and dropping the final sample shortens the x-scale
    /// while the live tracker is still placed from `distances`, putting the
    /// walker's own position past the end of the graph near the finish.
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
        // series stays strictly ascending without losing the route's end.
        var plotted: [ElevationSample] = []
        plotted.reserveCapacity(picked.count)
        for index in picked {
            let sample = samples[index]
            if let previous = plotted.last, sample.distanceMeters <= previous.distanceMeters {
                plotted[plotted.count - 1] = sample
            } else {
                plotted.append(sample)
            }
        }
        return plotted
    }

    /// Elevation min…max across the plotted samples, if any.
    var elevationRange: ClosedRange<Double>? {
        let elevations = samples.map(\.elevation)
        guard let low = elevations.min(), let high = elevations.max() else { return nil }
        return low...high
    }

    /// The route's full length in metres — the denominator behind every
    /// progress readout.
    var totalDistanceMeters: Double { distances.last ?? 0 }

    /// How far along the route a distance is, as a fraction of the whole,
    /// clamped to 0…1. `nil` for a route with no length, where a percentage
    /// would mean nothing.
    ///
    /// Deliberately the same arithmetic as `SharedTrailSnapshot.fractionComplete`,
    /// which the widget reads: both divide a matched distance-along-route by
    /// the same haversine total, so the app and the widget can't show two
    /// different percentages for one position.
    func fractionComplete(atDistance distance: Double) -> Double? {
        let total = totalDistanceMeters
        guard total > 0 else { return nil }
        return min(1, max(0, distance / total))
    }

    /// Distance still to walk from a position along the route, in metres.
    func remainingDistanceMeters(atDistance distance: Double) -> Double {
        max(0, totalDistanceMeters - distance)
    }

    /// Map coordinate at a distance along the route, interpolated within the
    /// bracketing segment. O(log n).
    func coordinate(atDistance target: Double) -> CLLocationCoordinate2D? {
        guard let firstDistance = distances.first, let lastDistance = distances.last,
              let firstCoordinate = coordinates.first, let lastCoordinate = coordinates.last
        else { return nil }
        if target <= firstDistance { return firstCoordinate }
        if target >= lastDistance { return lastCoordinate }

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
    func sample(atDistance target: Double) -> ElevationSample? {
        nearestIndex(in: sampleDistances, to: target).map { samples[$0] }
    }

    /// Projects an arbitrary coordinate (e.g. a live GPS fix) onto the route,
    /// used to auto-follow the elevation graph. Returns the distance-along-route
    /// of the nearest point on any route segment and how far off the route
    /// that point is, in meters — callers use the latter to decide whether the
    /// fix is actually near the trail. O(n): fine for a once-a-second poll.
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
    /// flip put a walker who had just set off at the *finish* of the trail
    /// about half the time — and because the match then becomes the continuity
    /// reference for every later fix, it stayed there for the whole hike.
    /// Preferring the earliest of the tied candidates starts them at the
    /// trailhead, and continuity carries them forward from there.
    ///
    /// `heading` — the walker's course over ground, when the fix carries one
    /// worth trusting (see ``LocationFixPolicy/course(of:)``) — settles that
    /// question outright, and outranks the assumption about the start. The two
    /// legs of an out-and-back run in opposite directions, so a walker already
    /// on the way back is going the *wrong* way for the outbound leg and the
    /// right way for the return one. It is consulted only when there is no
    /// `referenceDistance`: once a match exists, continuity is the better
    /// evidence, and letting a noisy course overrule it would reintroduce
    /// exactly the jumping this parameter set out to stop — a walker pausing
    /// to look back down the trail is not a walker who has turned around.
    ///
    /// A loop's junction stays ambiguous under this test, correctly: both
    /// passes run the same way, so the start assumption still decides it.
    func nearestPoint(
        to coordinate: CLLocationCoordinate2D,
        near referenceDistance: Double? = nil,
        heading: CLLocationDirection? = nil
    ) -> (distanceAlongRoute: Double, offRouteMeters: Double)? {
        guard !coordinates.isEmpty else { return nil }
        guard coordinates.count > 1 else {
            let only = coordinates[0]
            let offset = RouteGeometry.distanceMeters(from: coordinate, to: only)
            return (0, offset)
        }

        func candidate(at index: Int) -> NearestCandidate {
            let projection = RouteGeometry.project(
                coordinate,
                onSegmentFrom: coordinates[index],
                to: coordinates[index + 1]
            )
            return NearestCandidate(
                distanceAlongRoute: distances[index]
                    + projection.fraction
                        * (distances[index + 1] - distances[index]),
                offRouteMeters: projection.offRouteMeters,
                dx: projection.dx,
                dy: projection.dy
            )
        }

        var best = NearestCandidate(distanceAlongRoute: 0, offRouteMeters: .greatestFiniteMagnitude, dx: 0, dy: 0)
        for index in 0..<(coordinates.count - 1) {
            let result = candidate(at: index)
            if result.offRouteMeters < best.offRouteMeters {
                best = result
            }
        }

        let anchor = referenceDistance ?? 0
        let course = referenceDistance == nil ? heading : nil

        func runsWithTheWalker(_ candidate: NearestCandidate) -> Bool {
            guard let course else { return false }
            return Self.bearingDifference(course, candidate.bearingDegrees) < Self.courseAgreementDegrees
        }

        // Among every segment projection within `tieBreakToleranceMeters` of
        // the closest one, prefer whichever the walker is actually heading
        // along; failing that (or between two that both qualify), whichever
        // is nearest the anchor.
        return breakTie(
            among: (0..<(coordinates.count - 1)).map { candidate(at: $0) },
            best: best,
            anchor: anchor,
            runsWithTheWalker: runsWithTheWalker
        )
    }

    private struct NearestCandidate {
        let distanceAlongRoute: Double
        let offRouteMeters: Double
        let dx: Double
        let dy: Double
        var bearingDegrees: Double { atan2(dx, dy) * 180 / .pi }
    }

    private func breakTie(
        among candidates: [NearestCandidate],
        best: NearestCandidate,
        anchor: Double,
        runsWithTheWalker: (NearestCandidate) -> Bool
    ) -> (distanceAlongRoute: Double, offRouteMeters: Double) {
        let tieBreakToleranceMeters = 20.0
        var tied = best
        var tiedRunsWith = runsWithTheWalker(best)
        var bestContinuity = abs(best.distanceAlongRoute - anchor)
        for contender in candidates {
            guard contender.offRouteMeters <= best.offRouteMeters + tieBreakToleranceMeters else { continue }
            let contenderRunsWith = runsWithTheWalker(contender)
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
        return (tied.distanceAlongRoute, tied.offRouteMeters)
    }

    /// Smallest absolute angle between two compass bearings, 0…180°.
    private static func bearingDifference(_ a: Double, _ b: Double) -> Double {
        let delta = abs(a - b).truncatingRemainder(dividingBy: 360)
        return delta > 180 ? 360 - delta : delta
    }

    /// Index of the value in an ascending array closest to `target`. O(log n).
    private func nearestIndex(in sorted: [Double], to target: Double) -> Int? {
        guard let first = sorted.first, let last = sorted.last else { return nil }
        if target <= first { return 0 }
        if target >= last { return sorted.count - 1 }

        // First index at or past `target`; the endpoints are handled above, so
        // it is always strictly interior and `upper - 1` is always valid.
        let upper = sorted.partitioningIndex { $0 >= target }
        let lower = upper - 1
        return abs(sorted[upper] - target) < abs(sorted[lower] - target) ? upper : lower
    }
}
