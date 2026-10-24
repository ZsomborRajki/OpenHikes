//
//  WatchRecordingStats.swift
//  OpenHikesWatch
//
//  The figures that change while a hiker walks, held apart from everything
//  that does not.
//
//  This is the render-isolation rule the repository instructions set, on the
//  device where it matters most. A GPS fix arrives about once a second, and
//  every heart-rate sample is another change; if the screen's root body read
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
    /// `nil` until two fixes have carried a trusted height, so the screen
    /// draws a dash rather than a climb of zero nobody has measured.
    private(set) var elevationGainMeters: Double?
    private(set) var averageSpeedMetersPerSecond: Double?
    /// Beats per minute, from the workout session's own live samples, and
    /// when that sample was taken. `nil` until the first one arrives. After
    /// that it is the last reading, not a live one: the builder never goes
    /// back to having none, so a sensor that stops reading — a loosened band,
    /// a sleeve, a watch off the wrist — leaves its last number here. Whether
    /// it is still the heart rate is ``WatchRecordingFigures``'s call, made
    /// from the sample time.
    private(set) var heartRateBPM: Double?
    private(set) var heartRateSampledAt: Date?
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

    func update(heartRateBPM: Double?, sampledAt: Date?) {
        self.heartRateBPM = heartRateBPM
        heartRateSampledAt = sampledAt
    }

    func reset() {
        distanceMeters = 0
        activeSeconds = 0
        elevationGainMeters = nil
        averageSpeedMetersPerSecond = nil
        heartRateBPM = nil
        heartRateSampledAt = nil
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
    var elevationGainMeters: Double?
    var averageSpeedMetersPerSecond: Double?
    var fixCount: Int
}
