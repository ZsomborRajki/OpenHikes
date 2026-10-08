//
//  RouteProfile+Climb.swift
//  OpenHikes
//
//  What one stretch of a route climbs and drops — the question a walk asks
//  about the part still ahead of it, and about the part it has already
//  covered.
//

import Algorithms
import Foundation

nonisolated public extension RouteProfile {
    /// The ascent and descent between two distances along the route, walked
    /// from the lower towards the higher, or `nil` when fewer than two heights
    /// fall inside it.
    ///
    /// Through ``ElevationAccumulator``, the same deadband every other climb
    /// in the app is counted with, so a stretch's figure agrees with the
    /// detail screen's for the whole route. O(log n) to find the stretch and
    /// linear in the heights inside it — cheap enough to ask per matched fix,
    /// which is how often a walk asks it.
    func climb(from start: Double, to end: Double) -> (gainMeters: Double, lossMeters: Double)? {
        let lower = min(start, end)
        let upper = max(start, end)
        var accumulator = ElevationAccumulator()
        let first = samples.partitioningIndex { $0.distanceMeters >= lower }
        for sample in samples[first...] {
            guard sample.distanceMeters <= upper else { break }
            accumulator.record(sample.elevation)
        }
        guard accumulator.hasChange else { return nil }
        return (accumulator.gainMeters, accumulator.lossMeters)
    }

    /// What `stretches` climb and drop between them: each one's
    /// ``climb(from:to:)``, added up — the part of a route a walk has covered
    /// is rarely one stretch. `nil` when none of them had two heights to
    /// compare.
    func climb(over stretches: [ClosedRange<Double>]) -> (gainMeters: Double, lossMeters: Double)? {
        let climbs = stretches.compactMap { climb(from: $0.lowerBound, to: $0.upperBound) }
        guard !climbs.isEmpty else { return nil }
        return climbs.reduce((gainMeters: 0, lossMeters: 0)) { total, climb in
            (total.gainMeters + climb.gainMeters, total.lossMeters + climb.lossMeters)
        }
    }
}
