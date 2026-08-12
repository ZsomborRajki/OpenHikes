//
//  Hike+Statistics.swift
//  OpenTrails
//
//  Derived statistics computed from a Hike's route points.
//

import Foundation
import CoreLocation

extension Hike {
    var pointCount: Int { route.count }

    var elevations: [Double] { route.compactMap(\.elevation) }
    var timestamps: [Date] { route.compactMap(\.timestamp) }

    var startDate: Date? { timestamps.first }
    var endDate: Date? { timestamps.last }

    /// Elapsed time between the first and last timestamped points.
    var duration: TimeInterval? {
        guard let start = startDate, let end = endDate, end > start else { return nil }
        return end.timeIntervalSince(start)
    }

    var maxElevation: Measurement<UnitLength>? {
        elevations.max().map { Measurement(value: $0, unit: .meters) }
    }

    var minElevation: Measurement<UnitLength>? {
        elevations.min().map { Measurement(value: $0, unit: .meters) }
    }

    /// Cumulative climb over all points (sum of positive elevation deltas).
    var elevationGain: Measurement<UnitLength>? {
        elevationDelta(positive: true)
    }

    /// Cumulative descent over all points (sum of negative elevation deltas).
    var elevationLoss: Measurement<UnitLength>? {
        elevationDelta(positive: false)
    }

    private func elevationDelta(positive: Bool) -> Measurement<UnitLength>? {
        let e = elevations
        guard e.count > 1 else { return nil }
        var total = 0.0
        for i in 1..<e.count {
            let d = e[i] - e[i - 1]
            if (positive && d > 0) || (!positive && d < 0) { total += abs(d) }
        }
        return Measurement(value: total, unit: .meters)
    }

    /// Distance ÷ moving time.
    var averageSpeed: Measurement<UnitSpeed>? {
        guard let duration, duration > 0 else { return nil }
        return Measurement(value: distanceMeters / duration, unit: .metersPerSecond)
    }

    /// Fastest instantaneous pace between two consecutive timestamped points.
    var maxSpeed: Measurement<UnitSpeed>? {
        guard route.count > 1 else { return nil }
        var best = 0.0
        for i in 1..<route.count {
            guard let t0 = route[i - 1].timestamp, let t1 = route[i].timestamp else { continue }
            let dt = t1.timeIntervalSince(t0)
            guard dt > 0 else { continue }
            let a = CLLocation(latitude: route[i - 1].latitude, longitude: route[i - 1].longitude)
            let b = CLLocation(latitude: route[i].latitude, longitude: route[i].longitude)
            best = max(best, b.distance(from: a) / dt)
        }
        return best > 0 ? Measurement(value: best, unit: .metersPerSecond) : nil
    }
}
