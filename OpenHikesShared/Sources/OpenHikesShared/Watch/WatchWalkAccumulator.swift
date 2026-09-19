//
//  WatchWalkAccumulator.swift
//  OpenHikesShared
//
//  What a watch recording adds up to while it is happening: the fixes it
//  accepted, the distance, the climb, and the clock with its pauses taken out.
//
//  ## Why the arithmetic is here rather than on the watch
//
//  Because it is the half worth testing, and a watch app is the worst place in
//  this repository to test anything: there is no watch test bundle, no watch
//  simulator in any CI gate, and a `HKWorkoutSession` cannot be driven by a
//  suite. Put the accumulation behind a value type in the shared package and
//  `swift test` covers it on the macOS host in milliseconds, on the same
//  runner the three existing gates already use. What is left on the watch is
//  Core Location, HealthKit and SwiftUI — frameworks, not decisions.
//
//  ## Why it is not `RecordingDistanceAccumulator`
//
//  That one lives in the app, takes `CLLocation`s, and is wired into
//  barometric fusion, motion state and the trail matcher. None of those cross
//  to a watch: there is no barometer reading to fuse, no `CMMotionActivity` to
//  ask, and — deliberately — no matcher. What is left is the part that is the
//  same on both devices, which is a sum along a line and a sum of the rises.
//

import Foundation

/// Whether a fix is worth keeping in a watch recording.
///
/// The thresholds are `RecordingFixPolicy`'s, restated rather than imported
/// because that type lives in the app target and takes `CLLocation`s. They are
/// the same numbers on purpose — a hiker recording with a watch and a phone on
/// the same walk should not end up with two tracks that disagree about which
/// fixes were real — and `WatchFixPolicyParityTests` in the app bundle is what
/// fails when one of them moves and the other does not.
///
/// What is deliberately *not* here is the phone's speed gate and its
/// course-change escape. Both need a reported speed and course this does not
/// take, and the phone's own comment explains that the speed gate is a delay
/// rather than a rejection past `maximumInterval` anyway. The watch keeps the
/// two gates that need nothing but a position and a clock.
public enum WatchFixPolicy {
    /// Worse than this and the fix is not a position, it is a neighbourhood.
    public static let maximumHorizontalAccuracy: Double = 50
    /// Below this the hiker has not moved, they have stood still while the
    /// receiver wandered.
    public static let minimumDisplacement: Double = 5
    /// How long a stationary hiker goes unrecorded before a fix is kept
    /// anyway, so a rest stop leaves a timestamp rather than a gap.
    public static let maximumInterval: TimeInterval = 10

    /// Whether to keep `candidate`, given the last fix that was kept.
    public static func accepts(
        latitude: Double,
        longitude: Double,
        timestamp: Date,
        horizontalAccuracy: Double,
        after previous: WatchRecordedFix?
    ) -> Bool {
        guard horizontalAccuracy > 0,
              horizontalAccuracy <= maximumHorizontalAccuracy,
              Mercator.isRepresentable(latitude: latitude, longitude: longitude)
        else { return false }
        guard let previous else { return true }
        let interval = timestamp.timeIntervalSince(previous.timestamp)
        // A reordered pair, which two deliveries racing can produce and which
        // would otherwise add a negative leg to the distance.
        guard interval > 0 else { return false }
        if interval >= maximumInterval { return true }
        let displacement = WatchGeodesy.distanceMeters(
            fromLatitude: previous.latitude,
            longitude: previous.longitude,
            toLatitude: latitude,
            longitude: longitude
        )
        // The same shape the phone's displacement gate has: a fix has to move
        // further than the receiver's own claimed error before it counts as
        // movement, so a hiker standing at a viewpoint does not accumulate the
        // half kilometre of GPS wander that would otherwise be their walk.
        return displacement >= max(minimumDisplacement, horizontalAccuracy * 0.5)
    }
}

/// The running totals of a watch recording.
public struct WatchWalkAccumulator: Sendable, Equatable {
    /// How much a pair of consecutive heights must differ by before it counts
    /// as climbing rather than as the receiver breathing.
    ///
    /// A barometric altimeter on a still wrist drifts by a metre or two, and a
    /// six-hour walk is thousands of readings — unfiltered, that noise alone
    /// adds hundreds of metres of "climb" to a flat towpath.
    public static let elevationNoiseFloorMeters: Double = 1

    public private(set) var fixes: [WatchRecordedFix] = []
    public private(set) var distanceMeters: Double = 0
    public private(set) var elevationGainMeters: Double = 0
    public private(set) var elevationLossMeters: Double = 0
    /// Seconds between consecutive kept fixes, which is the walk's clock with
    /// its pauses already out of it: a pause stops fixes arriving, and the
    /// first one after a resume opens a new leg rather than closing the old.
    ///
    /// The same measure `PreparedRecording.recordedSeconds` is on the phone,
    /// and chosen over wall clock minus the pauses for the reason the
    /// repository instructions give: a list of pause intervals is not a
    /// complete record of when a recording was not running.
    public private(set) var activeSeconds: TimeInterval = 0

    /// Set while the recording is paused, so the next accepted fix is marked
    /// as the one that ended it.
    private var isResuming = false
    /// The last height that counted, which is what the noise floor is measured
    /// from — not the previous fix's, or a slow drift would be admitted a
    /// centimetre at a time.
    private var lastCountedElevation: Double?

    public init() { /* every total starts at zero */ }

    public var lastFix: WatchRecordedFix? { fixes.last }

    /// Metres per second over the time actually spent walking, or `nil` before
    /// there is any. Pace rather than speed is the watch's own presentation
    /// choice; this is the figure both are read off.
    public var averageSpeedMetersPerSecond: Double? {
        guard activeSeconds > 0, distanceMeters > 0 else { return nil }
        return distanceMeters / activeSeconds
    }

    /// Offers a fix. Returns whether it was kept, so a caller can tell a
    /// rejected fix from an accepted one that happened to move nothing.
    @discardableResult public mutating func accept(
        latitude: Double,
        longitude: Double,
        timestamp: Date,
        horizontalAccuracy: Double,
        elevationMeters: Double? = nil
    ) -> Bool {
        guard WatchFixPolicy.accepts(
            latitude: latitude,
            longitude: longitude,
            timestamp: timestamp,
            horizontalAccuracy: horizontalAccuracy,
            after: fixes.last
        ) else { return false }

        let resumes = isResuming
        isResuming = false
        // A receiver can report a non-finite altitude, and this app has seen
        // one — the phone's own sensor gate checks `altitude.isFinite` beside
        // the vertical accuracy for exactly that. Dropped here rather than
        // carried onto the fix, because `JSONEncoder` refuses a non-finite
        // `Double`: one would make the *whole* finished walk unwritable and
        // unsendable, which on a watch is the only copy there is.
        let height = elevationMeters.flatMap { $0.isFinite ? $0 : nil }
        if let previous = fixes.last, !resumes {
            distanceMeters += WatchGeodesy.distanceMeters(
                fromLatitude: previous.latitude,
                longitude: previous.longitude,
                toLatitude: latitude,
                longitude: longitude
            )
            activeSeconds += timestamp.timeIntervalSince(previous.timestamp)
        }
        accumulateElevation(height, bridging: !resumes)
        fixes.append(
            WatchRecordedFix(
                latitude: latitude,
                longitude: longitude,
                timestamp: timestamp,
                horizontalAccuracy: horizontalAccuracy,
                elevationMeters: height,
                resumesAfterPause: resumes && !fixes.isEmpty
            )
        )
        return true
    }

    /// Marks the recording paused, so the next fix opens a new leg.
    ///
    /// Idempotent, because a pause can arrive from the watch's own button, the
    /// workout session's state and a resumed app all at once, and none of them
    /// knows about the others.
    public mutating func pause() { isResuming = true }

    /// What crosses to the phone, or `nil` if there is not a walk here.
    public func recordedWalk(
        sessionID: UUID,
        startedAt: Date,
        endedAt: Date,
        trailHikeID: UUID? = nil,
        title: String? = nil
    ) -> WatchRecordedWalk? {
        let walk = WatchRecordedWalk(
            sessionID: sessionID,
            startedAt: startedAt,
            endedAt: endedAt,
            distanceMeters: distanceMeters,
            activeSeconds: activeSeconds,
            fixes: fixes,
            trailHikeID: trailHikeID,
            title: title,
            elevationGainMeters: elevationGainMeters > 0 ? elevationGainMeters : nil,
            elevationLossMeters: elevationLossMeters > 0 ? elevationLossMeters : nil
        )
        return walk.isWorthKeeping ? walk : nil
    }

    /// - Parameter bridging: whether the rise from the last counted height to
    ///   this one is ground the hiker walked. Across a pause it is not, so the
    ///   height is adopted as the new reference without being climbed.
    private mutating func accumulateElevation(_ elevation: Double?, bridging: Bool) {
        guard let elevation, elevation.isFinite else { return }
        guard bridging, let last = lastCountedElevation else {
            lastCountedElevation = elevation
            return
        }
        let change = elevation - last
        guard abs(change) >= Self.elevationNoiseFloorMeters else { return }
        if change > 0 { elevationGainMeters += change } else { elevationLossMeters -= change }
        lastCountedElevation = elevation
    }
}
