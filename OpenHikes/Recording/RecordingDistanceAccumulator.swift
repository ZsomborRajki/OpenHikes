//
//  RecordingDistanceAccumulator.swift
//  OpenHikes
//

import CoreLocation
import Foundation
import OpenHikesShared

/// Distance accumulation that can retract a short window of GPS wander when
/// the walker has remained within one small area for long enough.
nonisolated struct RecordingDistanceAccumulator: Sendable {
    private(set) var distanceMeters = 0.0
    private(set) var isStationary = false
    /// Time actually spent recording: the sum of the gaps between consecutive
    /// accepted points, minus the gap a pause opened. Averaging distance over
    /// wall-clock instead would let a long lunch stop drag the pace down for a
    /// walk the recorder wasn't even watching.
    private(set) var recordedDuration = 0.0

    private var previous: RecordingPoint?
    private var movementWindowStart: RecordingPoint?
    private var movementWindowDistance = 0.0
    private var stationaryAnchor: RecordingPoint?
    private var motionStationaryStartedAt: Date?

    private static let stationaryInterval: TimeInterval = 30
    private static let stationaryNetDisplacement: CLLocationDistance = 15
    private static let resumeDisplacement: CLLocationDistance = 20

    var averageSpeedMetersPerSecond: Double? {
        recordedDuration > 0 ? distanceMeters / recordedDuration : nil
    }

    @discardableResult mutating func append(_ point: RecordingPoint) -> Double {
        guard let previous else {
            previous = point
            movementWindowStart = point
            _ = updateMotionStationaryStart(for: point)
            return distanceMeters
        }

        if point.flags.contains(.resumed) {
            return handleResumed(point)
        }

        let beganMotionStationary = updateMotionStationaryStart(for: point)
        recordedDuration += max(
            0,
            point.timestamp.timeIntervalSince(previous.timestamp)
        )

        if let result = handleStationary(point, previous: previous) {
            return result
        }

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
        guard isStationary else {
            return nil
        }
        let anchor = stationaryAnchor ?? previous
        let displacement = RouteGeometry.distanceMeters(
            from: anchor.coordinate,
            to: point.coordinate
        )
        self.previous = point
        if point.flags.contains(.motionStationary) {
            return distanceMeters
        }
        guard displacement > Self.resumeDisplacement else {
            return distanceMeters
        }
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
                >= Self.stationaryInterval
        else {
            return distanceMeters
        }

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
            guard motionStationaryStartedAt == nil else {
                return false
            }
            motionStationaryStartedAt = point.timestamp
            return true
        }
        motionStationaryStartedAt = nil
        return false
    }
}
