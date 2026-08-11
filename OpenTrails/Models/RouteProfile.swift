//
//  RouteProfile.swift
//  OpenTrails
//
//  Precomputed distance/elevation index for a route. Built once (O(n)) so that
//  scrubbing the elevation chart resolves a map location in O(log n) via binary
//  search — no per-drag recomputation.
//

import Foundation
import CoreLocation

nonisolated struct RouteProfile {
    /// How far off the route (in meters) a GPS fix can be and still count as
    /// "on the trail" — shared by every consumer of `nearestPoint(to:near:)`
    /// (in-app auto-follow, the foreground/background widget feeds) so they
    /// all agree on the same trail.
    static let followMatchThresholdMeters: Double = 75

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
        var coordinates: [CLLocationCoordinate2D] = []
        var distances: [Double] = []
        var samples: [ElevationSample] = []
        coordinates.reserveCapacity(route.count)
        distances.reserveCapacity(route.count)

        var cumulative = 0.0
        var previous: CLLocationCoordinate2D?
        for point in route {
            let coordinate = point.clCoordinate
            if let previous {
                cumulative += RouteGeometry.distanceMeters(from: previous, to: coordinate)
            }
            previous = coordinate
            coordinates.append(coordinate)
            distances.append(cumulative)
            if let elevation = point.elevation {
                samples.append(ElevationSample(distanceMeters: cumulative, elevation: elevation))
            }
        }

        let plotted = Self.downsampledForDrawing(samples)
        self.coordinates = coordinates
        self.distances = distances
        self.samples = plotted
        self.sampleDistances = plotted.map(\.distanceMeters)
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
                if samples[index].elevation < samples[lowest].elevation { lowest = index }
                if samples[index].elevation > samples[highest].elevation { highest = index }
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

    /// Map coordinate at a distance along the route, interpolated within the
    /// bracketing segment. O(log n).
    func coordinate(atDistance target: Double) -> CLLocationCoordinate2D? {
        guard let firstDistance = distances.first, let lastDistance = distances.last,
              let firstCoordinate = coordinates.first, let lastCoordinate = coordinates.last
        else { return nil }
        if target <= firstDistance { return firstCoordinate }
        if target >= lastDistance { return lastCoordinate }

        let upper = lowerBound(in: distances, for: target)
        let lower = upper - 1
        let segmentLength = distances[upper] - distances[lower]
        guard segmentLength > 0 else { return coordinates[upper] }
        let fraction = (target - distances[lower]) / segmentLength
        return Self.interpolate(from: coordinates[lower], to: coordinates[upper], fraction: fraction)
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
    func nearestPoint(to coordinate: CLLocationCoordinate2D, near referenceDistance: Double? = nil) -> (distanceAlongRoute: Double, offRouteMeters: Double)? {
        guard !coordinates.isEmpty else { return nil }
        guard coordinates.count > 1 else {
            let only = coordinates[0]
            let offset = RouteGeometry.distanceMeters(from: coordinate, to: only)
            return (0, offset)
        }

        struct Candidate {
            let distanceAlongRoute: Double
            let offRouteMeters: Double
        }

        func candidate(at index: Int) -> Candidate {
            let start = Self.localOffset(from: coordinate, to: coordinates[index])
            let end = Self.localOffset(from: coordinate, to: coordinates[index + 1])
            let dx = end.x - start.x
            let dy = end.y - start.y
            let lengthSquared = dx * dx + dy * dy
            let fraction = lengthSquared > 0
                ? min(max(-(start.x * dx + start.y * dy) / lengthSquared, 0), 1)
                : 0
            let projectedX = start.x + fraction * dx
            let projectedY = start.y + fraction * dy
            return Candidate(
                distanceAlongRoute: distances[index] + fraction * (distances[index + 1] - distances[index]),
                offRouteMeters: hypot(projectedX, projectedY)
            )
        }

        var best = Candidate(distanceAlongRoute: 0, offRouteMeters: .greatestFiniteMagnitude)
        for index in 0..<(coordinates.count - 1) {
            let candidate = candidate(at: index)
            if candidate.offRouteMeters < best.offRouteMeters { best = candidate }
        }

        guard let referenceDistance else {
            return (best.distanceAlongRoute, best.offRouteMeters)
        }

        // Among every segment projection within `tieBreakToleranceMeters` of
        // the closest one, prefer whichever is nearest the previous match.
        let tieBreakToleranceMeters = 20.0
        var tied = best
        var bestContinuity = abs(best.distanceAlongRoute - referenceDistance)
        for index in 0..<(coordinates.count - 1) {
            let candidate = candidate(at: index)
            guard candidate.offRouteMeters <= best.offRouteMeters + tieBreakToleranceMeters else { continue }
            let continuity = abs(candidate.distanceAlongRoute - referenceDistance)
            if continuity < bestContinuity {
                bestContinuity = continuity
                tied = candidate
            }
        }
        return (tied.distanceAlongRoute, tied.offRouteMeters)
    }

    private static func localOffset(
        from origin: CLLocationCoordinate2D,
        to coordinate: CLLocationCoordinate2D
    ) -> (x: Double, y: Double) {
        let earthRadius = 6_371_008.8
        let latitudeRadians = origin.latitude * .pi / 180
        let longitudeDelta = normalizedLongitudeDelta(coordinate.longitude - origin.longitude)
        return (
            x: longitudeDelta * .pi / 180 * earthRadius * cos(latitudeRadians),
            y: (coordinate.latitude - origin.latitude) * .pi / 180 * earthRadius
        )
    }

    private static func interpolate(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D,
        fraction: Double
    ) -> CLLocationCoordinate2D {
        let longitude = start.longitude + normalizedLongitudeDelta(end.longitude - start.longitude) * fraction
        return CLLocationCoordinate2D(
            latitude: start.latitude + (end.latitude - start.latitude) * fraction,
            longitude: normalizedLongitude(longitude)
        )
    }

    private static func normalizedLongitudeDelta(_ delta: Double) -> Double {
        var normalized = delta.truncatingRemainder(dividingBy: 360)
        if normalized > 180 { normalized -= 360 }
        if normalized < -180 { normalized += 360 }
        return normalized
    }

    private static func normalizedLongitude(_ longitude: Double) -> Double {
        var normalized = longitude.truncatingRemainder(dividingBy: 360)
        if normalized >= 180 { normalized -= 360 }
        if normalized < -180 { normalized += 360 }
        return normalized
    }

    /// Index of the value in an ascending array closest to `target`. O(log n).
    private func nearestIndex(in sorted: [Double], to target: Double) -> Int? {
        guard let first = sorted.first, let last = sorted.last else { return nil }
        if target <= first { return 0 }
        if target >= last { return sorted.count - 1 }

        var low = 0
        var high = sorted.count - 1
        while low < high {
            let mid = (low + high) / 2
            if sorted[mid] < target { low = mid + 1 } else { high = mid }
        }
        let lower = low - 1
        return abs(sorted[low] - target) < abs(sorted[lower] - target) ? low : lower
    }

    private func lowerBound(in sorted: [Double], for target: Double) -> Int {
        var low = 0
        var high = sorted.count
        while low < high {
            let mid = (low + high) / 2
            if sorted[mid] < target {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }
}
