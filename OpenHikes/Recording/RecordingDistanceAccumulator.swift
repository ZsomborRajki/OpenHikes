//
//  RecordingDistanceAccumulator.swift
//  OpenHikes
//

import CoreLocation
import DequeModule
import Foundation

/// Distance accumulation that can retract a short window of GPS wander when
/// the walker has remained within one small area for long enough.
///
/// It also keeps the recording's running elevation totals. Not because climb
/// and distance belong together, but because this is the one place every
/// accepted point passes through exactly once — on the live path and on the
/// replay that rebuilds state from the journal — so a total kept here cannot
/// be left behind by a reset that only half the paths know about.
nonisolated struct RecordingDistanceAccumulator: Sendable {
    private(set) var distanceMeters = 0.0
    private(set) var isStationary = false
    /// Time actually spent recording: the sum of the gaps between consecutive
    /// accepted points, minus the gap a pause opened. Averaging distance over
    /// wall-clock instead would let a long lunch stop drag the pace down for a
    /// walk the recorder wasn't even watching.
    private(set) var recordedDuration = 0.0

    private var elevation = ElevationAccumulator()
    private var previous: RecordingPoint?
    private var movementWindowStart: RecordingPoint?
    private var movementWindowDistance = 0.0
    private var stationaryAnchor: RecordingPoint?
    private var motionStationaryStartedAt: Date?
    /// Moving time, by the same rule a *saved* route is measured with.
    ///
    /// Deliberately `MovingTimeAccumulator` rather than a second subtraction
    /// off ``recordedDuration``: a walker who watched "2h 10m moving" tick
    /// during the hike and then opens the saved hike to find "1h 58m" has
    /// been shown two numbers with one name, and neither is checkable. This
    /// is the same type the detail screen's figure comes from, fed the same
    /// points, so the live readout is a preview of the saved one rather than
    /// an independent estimate of it.
    private var movingTime = MovingTimeAccumulator()
    /// The trailing window the live speed is read off, oldest first: each
    /// entry is a fix's timestamp against the total distance as it stood
    /// after that fix. Bounded by ``recentSpeedWindow`` rather than by the
    /// length of the walk, so a six-hour hike holds a couple of dozen entries
    /// here rather than thousands.
    private var recentWindow: Deque<RecentSample> = []

    private struct RecentSample {
        let timestamp: Date
        let distanceMeters: Double
    }

    /// How long a walker has to stay inside one small area before the
    /// recording stops calling it walking, and how small that area is.
    ///
    /// Not private, because ``MovingTimeAccumulator`` answers the same
    /// question about a saved route that this answers live, and "standing
    /// still" has to mean one thing in both. A second copy of these two
    /// numbers would be free to drift, and neither reading would be wrong
    /// enough to notice.
    static let stationaryInterval: TimeInterval = 30
    static let stationaryNetDisplacement: CLLocationDistance = 15
    private static let resumeDisplacement: CLLocationDistance = 20

    /// How far back ``recentSpeedMetersPerSecond`` looks.
    ///
    /// Five minutes is the shortest window that survives the thing it is for.
    /// A live speed exists because the average stops moving — an hour in, a
    /// steep half-kilometre barely disturbs it — and the walker wants to know
    /// what they are doing *now*. Any shorter and it is reporting GPS noise
    /// and the gaps between fixes rather than the walk: accepted fixes can be
    /// ten seconds apart on open ground and a minute apart under trees, so a
    /// one-minute window is two samples in the woods and thirty in a field,
    /// and would read as a speed that changes with the tree cover.
    static let recentSpeedWindow: TimeInterval = 300
    /// The shortest span that may be divided into a speed. Below it the answer
    /// is dominated by whichever two fixes happen to be in the window, so
    /// there is no figure rather than a jumpy one — which is also what the
    /// first minute of every walk gets.
    static let minimumRecentSpeedSpan: TimeInterval = 60

    var averageSpeedMetersPerSecond: Double? {
        recordedDuration > 0 ? distanceMeters / recordedDuration : nil
    }

    /// Seconds spent actually walking, as opposed to standing about with the
    /// recording running. Never `nil`: zero is the true answer for a walk that
    /// has not started moving, where distance-over-time has no answer at all.
    var movingSeconds: TimeInterval {
        movingTime.seconds
    }

    /// Speed over the last ``recentSpeedWindow``, or `nil` until the window
    /// spans ``minimumRecentSpeedSpan``.
    ///
    /// Clamped at zero because ``distanceMeters`` can be *retracted*: a
    /// stationary window hands back the wander it accumulated, which leaves
    /// the newest total below one taken minutes earlier. That is the intended
    /// behaviour of the retraction and reads correctly here as a speed of
    /// zero — the walker really has gone nowhere — rather than as the negative
    /// speed the subtraction literally produces.
    var recentSpeedMetersPerSecond: Double? {
        guard let anchor = recentWindow.first,
              let latest = recentWindow.last else { return nil }
        let span = latest.timestamp.timeIntervalSince(anchor.timestamp)
        guard span >= Self.minimumRecentSpeedSpan else { return nil }
        return max(0, latest.distanceMeters - anchor.distanceMeters) / span
    }

    /// Metres climbed so far, or `nil` until two points have carried a
    /// trusted altitude — see ``ElevationAccumulator/hasChange``.
    ///
    /// Unlike distance, this is never retracted. A stationary window is GPS
    /// wandering across the ground, which the altitude filter has already
    /// smoothed vertically; subtracting a climb that the walker's own legs
    /// may well have made would be the larger error.
    var elevationGainMeters: Double? {
        elevation.hasChange ? elevation.gainMeters : nil
    }

    /// Feeds one accepted fix in and reports the distance total after it.
    ///
    /// The three measures are updated in one place because this is the one
    /// place every accepted point passes through exactly once — on the live
    /// path and on the replay that rebuilds state from the journal. A moving
    /// clock or a speed window fed from either of those call sites alone
    /// would be silently wrong after a recovery.
    @discardableResult mutating func append(_ point: RecordingPoint) -> Double {
        // A resume is a new segment, not a continuation. Both of these
        // measure across the gap between consecutive points, so carrying
        // either one over a pause would book the whole pause — an hour at
        // lunch, on a walk that recorded none of it — as walking.
        //
        // The moving clock resets itself: the point below carries the pause
        // through as a ``RouteBoundary``, and ``MovingTimeAccumulator/record(_:)``
        // drops the leg and its window there. Replacing the accumulator
        // outright — which is what this used to do — also discarded the
        // seconds already walked, so the live readout fell back to zero the
        // moment a walker resumed.
        if point.flags.contains(.resumed) {
            recentWindow.removeAll(keepingCapacity: true)
        }
        let distance = accumulate(point)
        movingTime.record(point.routeCoordinate)
        appendRecentSample(at: point.timestamp, distanceMeters: distance)
        return distance
    }

    /// Trims the trailing window and adds `point` to it.
    ///
    /// The window keeps the newest sample that is still a full
    /// ``recentSpeedWindow`` behind the latest, rather than dropping
    /// everything older than the cutoff: dropping them all would leave the
    /// span shorter than the window and the speed measured over whatever was
    /// left. It is the same shape ``MovingTimeAccumulator/trim(newest:)``
    /// uses, for the same reason.
    private mutating func appendRecentSample(
        at timestamp: Date,
        distanceMeters: Double
    ) {
        // A fix that does not advance the clock cannot bound a speed, and
        // making it the anchor would divide by a span running backwards.
        // `RecordingFixPolicy` refuses these live; a journal replayed after a
        // crash is the path that can still carry one.
        if let latest = recentWindow.last,
           timestamp <= latest.timestamp { return }
        recentWindow.append(
            RecentSample(timestamp: timestamp, distanceMeters: distanceMeters)
        )
        while recentWindow.count > 1,
              timestamp.timeIntervalSince(recentWindow[1].timestamp)
                  >= Self.recentSpeedWindow {
            recentWindow.removeFirst()
        }
    }

    private mutating func accumulate(_ point: RecordingPoint) -> Double {
        elevation.record(point.elevation)
        guard let previous else {
            previous = point
            movementWindowStart = point
            _ = updateMotionStationaryStart(for: point)
            return distanceMeters
        }

        if point.flags.contains(.resumed) { return handleResumed(point) }

        let beganMotionStationary = updateMotionStationaryStart(for: point)
        recordedDuration += max(
            0,
            point.timestamp.timeIntervalSince(previous.timestamp)
        )

        if let result = handleStationary(point, previous: previous) { return result }

        let leg = RouteGeometry.distanceMeters(
            from: previous.coordinate,
            to: point.coordinate
        )
        distanceMeters += leg
        movementWindowDistance += leg
        self.previous = point
        return updateMovementWindow(point: point, beganMotionStationary: beganMotionStationary)
    }

    private mutating func handleResumed(_ point: RecordingPoint) -> Double {
        previous = point
        movementWindowStart = point
        movementWindowDistance = 0
        stationaryAnchor = nil
        isStationary = false
        _ = updateMotionStationaryStart(for: point)
        return distanceMeters
    }

    private mutating func handleStationary(
        _ point: RecordingPoint,
        previous: RecordingPoint
    ) -> Double? {
        guard isStationary else { return nil }
        let anchor = stationaryAnchor ?? previous
        let displacement = RouteGeometry.distanceMeters(
            from: anchor.coordinate,
            to: point.coordinate
        )
        self.previous = point
        if point.flags.contains(.motionStationary) { return distanceMeters }
        guard displacement > Self.resumeDisplacement else { return distanceMeters }
        isStationary = false
        stationaryAnchor = nil
        distanceMeters += displacement
        movementWindowStart = point
        movementWindowDistance = 0
        return distanceMeters
    }

    private mutating func updateMovementWindow(
        point: RecordingPoint,
        beganMotionStationary: Bool
    ) -> Double {
        if beganMotionStationary {
            movementWindowStart = point
            movementWindowDistance = 0
            return distanceMeters
        }

        guard let movementWindowStart,
              point.timestamp.timeIntervalSince(movementWindowStart.timestamp)
                >= Self.stationaryInterval else { return distanceMeters }

        let netDisplacement = RouteGeometry.distanceMeters(
            from: movementWindowStart.coordinate,
            to: point.coordinate
        )
        let motionConfirmsStationary = motionStationaryStartedAt.map { startedAt in
            point.timestamp.timeIntervalSince(startedAt)
                >= Self.stationaryInterval
        } ?? false
        if netDisplacement < Self.stationaryNetDisplacement
            || motionConfirmsStationary {
            distanceMeters = max(0, distanceMeters - movementWindowDistance)
            movementWindowDistance = 0
            stationaryAnchor = movementWindowStart
            isStationary = true
        } else {
            self.movementWindowStart = point
            movementWindowDistance = 0
        }
        return distanceMeters
    }

    private mutating func updateMotionStationaryStart(
        for point: RecordingPoint
    ) -> Bool {
        if point.flags.contains(.motionStationary) {
            guard motionStationaryStartedAt == nil else { return false }
            motionStationaryStartedAt = point.timestamp
            return true
        }
        motionStationaryStartedAt = nil
        return false
    }
}
