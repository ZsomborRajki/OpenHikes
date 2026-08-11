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
        var previous: CLLocation?
        for point in route {
            let location = CLLocation(latitude: point.latitude, longitude: point.longitude)
            if let previous { cumulative += location.distance(from: previous) }
            previous = location
            coordinates.append(point.clCoordinate)
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

    /// Map coordinate nearest to a distance along the route. O(log n).
    func coordinate(atDistance target: Double) -> CLLocationCoordinate2D? {
        nearestIndex(in: distances, to: target).map { coordinates[$0] }
    }

    /// Elevation sample nearest to a distance along the route. O(log n).
    func sample(atDistance target: Double) -> ElevationSample? {
        nearestIndex(in: sampleDistances, to: target).map { samples[$0] }
    }

    /// Projects an arbitrary coordinate (e.g. a live GPS fix) onto the route,
    /// used to auto-follow the elevation graph. Returns the distance-along-route
    /// of the nearest track point and how far off the route that point is, in
    /// meters — callers use the latter to decide whether the fix is actually
    /// near the trail. O(n): fine for a once-a-second poll.
    ///
    /// `referenceDistance`, when given (the previous match), breaks ties in
    /// favor of continuity. Loops, out-and-backs, and switchbacks can bring
    /// two very different points along the route within GPS-noise distance of
    /// each other (e.g. a loop's start and finish); without this, ordinary
    /// jitter can flip the match between them — jumping the tracker across
    /// most of the route with no real movement.
    func nearestPoint(to coordinate: CLLocationCoordinate2D, near referenceDistance: Double? = nil) -> (distanceAlongRoute: Double, offRouteMeters: Double)? {
        guard !coordinates.isEmpty else { return nil }
        let target = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)

        // Only the tie-break path below needs every point's offset — skip
        // building it when there's no reference to break ties against.
        let tracksOffsets = referenceDistance != nil
        var offsets: [Double] = []
        if tracksOffsets { offsets.reserveCapacity(coordinates.count) }
        var bestIndex = 0
        var bestDistance = Double.greatestFiniteMagnitude
        for (index, candidate) in coordinates.enumerated() {
            let distance = target.distance(from: CLLocation(latitude: candidate.latitude, longitude: candidate.longitude))
            if tracksOffsets { offsets.append(distance) }
            if distance < bestDistance {
                bestDistance = distance
                bestIndex = index
            }
        }

        guard let referenceDistance else {
            return (distances[bestIndex], bestDistance)
        }

        // Among every point within `tieBreakToleranceMeters` of the closest
        // one, prefer whichever is nearest the previous match rather than
        // always the single closest raw vertex.
        let tieBreakToleranceMeters = 20.0
        var bestTiedIndex = bestIndex
        var bestContinuity = abs(distances[bestIndex] - referenceDistance)
        for (index, distance) in offsets.enumerated() where distance <= bestDistance + tieBreakToleranceMeters {
            let continuity = abs(distances[index] - referenceDistance)
            if continuity < bestContinuity {
                bestContinuity = continuity
                bestTiedIndex = index
            }
        }
        // The tied vertex's own offset, not the raw-closest vertex's — they
        // can differ once tie-break actually picks a different index, and
        // callers gate on this value describing the point being returned.
        return (distances[bestTiedIndex], offsets[bestTiedIndex])
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
}
