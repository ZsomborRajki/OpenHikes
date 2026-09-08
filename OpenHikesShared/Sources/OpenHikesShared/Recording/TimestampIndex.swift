//
//  TimestampIndex.swift
//  OpenHikesShared
//

import Foundation

/// A sorted timestamp index optimized for proximity checks. Tolerance
/// boundaries are inclusive.
public struct TimestampIndex: Sendable {
    private let timestamps: [Date]

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

    /// The first index whose timestamp is at or after `timestamp`, or
    /// `endIndex` when none is.
    ///
    /// This is `timestamps.partitioningIndex { $0 >= timestamp }` written out
    /// by hand, and it stays that way deliberately. The app side of the same
    /// operation — ``RouteProfile``, ``MapState``, `HikePhotoTimeline` — uses
    /// swift-algorithms, but this package declares no external dependencies at
    /// all, and it is linked into the widget and Control Center extensions as
    /// well as the app. A whole module in three binaries is not a fair price
    /// for six lines whose behaviour is pinned by `TimestampIndexTests`.
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
