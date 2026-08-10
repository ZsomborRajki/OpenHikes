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
    func nearestPoint(to coordinate: CLLocationCoordinate2D) -> (distanceAlongRoute: Double, offRouteMeters: Double)? {
        guard !coordinates.isEmpty else { return nil }
        let target = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        var bestIndex = 0
        var bestDistance = Double.greatestFiniteMagnitude
        for (index, candidate) in coordinates.enumerated() {
            let distance = target.distance(from: CLLocation(latitude: candidate.latitude, longitude: candidate.longitude))
            if distance < bestDistance {
                bestDistance = distance
                bestIndex = index
            }
        }
        return (distances[bestIndex], bestDistance)
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
