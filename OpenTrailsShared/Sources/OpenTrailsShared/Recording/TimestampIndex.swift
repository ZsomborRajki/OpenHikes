//
//  TimestampIndex.swift
//  OpenTrailsShared
//

import Foundation

/// A sorted timestamp index optimized for proximity checks. Tolerance
/// boundaries are inclusive.
public struct TimestampIndex: Sendable {
    private var timestamps: [Date]

    public init<S: Sequence>(_ timestamps: S) where S.Element == Date {
        self.timestamps = timestamps.sorted()
    }

    public func contains(
        _ timestamp: Date,
        within tolerance: TimeInterval
    ) -> Bool {
        let clamped = max(0, tolerance)
        let earliest = timestamp.addingTimeInterval(-clamped)
        let candidate = lowerBound(for: earliest)
        guard candidate < timestamps.count else { return false }
        return timestamps[candidate]
            <= timestamp.addingTimeInterval(clamped)
    }

    private func lowerBound(for timestamp: Date) -> Int {
        var lower = timestamps.startIndex
        var upper = timestamps.endIndex
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if timestamps[middle] < timestamp {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower
    }
}
