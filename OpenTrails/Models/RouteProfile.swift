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

    /// All route coordinates, in order.
    let coordinates: [CLLocationCoordinate2D]
    /// Cumulative metres from the start, aligned with `coordinates`, ascending.
    let distances: [Double]
    /// Points that carry elevation, for charting.
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

        self.coordinates = coordinates
        self.distances = distances
        self.samples = samples
        self.sampleDistances = samples.map(\.distanceMeters)
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
