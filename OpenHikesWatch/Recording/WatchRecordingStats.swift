//
//  WatchRecordingStats.swift
//  OpenHikesWatch
//
//  The figures that change while a hiker walks, held apart from everything
//  that does not.
//
//  This is the render-isolation rule the repository instructions set, on the
//  device where it matters most. A GPS fix arrives about once a second and a
//  heart-rate sample more often than that; if the screen's root body read
//  these, every one of them would re-run the whole hierarchy — on a watch,
//  with a battery that has to last the walk these figures are describing.
//
//  So they live in a stable `@Observable` reference type that only the leaf
//  views showing them read. The root holds the object and never touches a
//  property on it. ``WatchFollowState`` next door is the same idea for the
//  trail-following figures, and is separate for the same reason
//  `SharedRecordingSnapshot` is separate from `SharedTrailSnapshot`: the two
//  change at different times and a screen showing one must not be re-run by
//  the other.
//

import Foundation
import Observation

@MainActor
@Observable
final class WatchRecordingStats {
    private(set) var distanceMeters: Double = 0
    private(set) var activeSeconds: TimeInterval = 0
    private(set) var elevationGainMeters: Double = 0
    private(set) var averageSpeedMetersPerSecond: Double?
    /// Beats per minute, from the workout session's own live samples. `nil`
    /// until the first one arrives, and on a watch whose sensor is covered by
    /// a sleeve — which is a state to say rather than a zero to draw.
    private(set) var heartRateBPM: Double?
    /// How many fixes the recording has kept, which is the honest answer to
    /// "is this working?" before there is enough distance to show one.
    private(set) var fixCount = 0

    func update(from accumulator: WatchWalkAccumulatorSnapshot) {
        distanceMeters = accumulator.distanceMeters
        activeSeconds = accumulator.activeSeconds
        elevationGainMeters = accumulator.elevationGainMeters
        averageSpeedMetersPerSecond = accumulator.averageSpeedMetersPerSecond
        fixCount = accumulator.fixCount
    }

    func update(heartRateBPM: Double?) {
        self.heartRateBPM = heartRateBPM
    }

    func reset() {
        distanceMeters = 0
        activeSeconds = 0
        elevationGainMeters = 0
        averageSpeedMetersPerSecond = nil
        heartRateBPM = nil
        fixCount = 0
    }
}

/// What the recorder reads off its accumulator to publish.
///
/// A struct rather than the accumulator itself, so nothing on the drawing side
/// can reach the whole fix array — which grows to thousands of points on a
/// long walk and has no business crossing into a view.
struct WatchWalkAccumulatorSnapshot: Sendable, Equatable {
    var distanceMeters: Double
    var activeSeconds: TimeInterval
    var elevationGainMeters: Double
    var averageSpeedMetersPerSecond: Double?
    var fixCount: Int
}
