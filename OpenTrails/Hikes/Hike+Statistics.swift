//
//  Hike+Statistics.swift
//  OpenTrails
//
//  Derived statistics computed from a Hike's route points.
//

import Foundation

nonisolated struct HikeRouteStatistics: Sendable {
    private struct Accumulator {
        var firstTimestamp: Date?
        var lastTimestamp: Date?
        var previousElevation: Double?
        var elevationCount = 0
        var minimumElevation: Double?
        var maximumElevation: Double?
        var gainMeters = 0.0
        var lossMeters = 0.0
        var fastestMetersPerSecond = 0.0
        var previousPoint: RouteCoordinate?

        var duration: TimeInterval? {
            guard let firstTimestamp,
                  let lastTimestamp,
                  lastTimestamp > firstTimestamp else {
                return nil
            }
            return lastTimestamp.timeIntervalSince(firstTimestamp)
        }

        mutating func consume(_ point: RouteCoordinate) {
            record(timestamp: point.timestamp)
            record(elevation: point.elevation)
            recordSpeed(to: point)
            previousPoint = point
        }

        private mutating func record(timestamp: Date?) {
            guard let timestamp else {
                return
            }
            if firstTimestamp == nil {
                firstTimestamp = timestamp
            }
            lastTimestamp = timestamp
        }

        private mutating func record(elevation: Double?) {
            guard let elevation else {
                return
            }
            elevationCount += 1
            minimumElevation = min(minimumElevation ?? elevation, elevation)
            maximumElevation = max(maximumElevation ?? elevation, elevation)
            if let previousElevation {
                let delta = elevation - previousElevation
                if delta > 0 {
                    gainMeters += delta
                } else if delta < 0 {
                    lossMeters -= delta
                }
            }
            previousElevation = elevation
        }

        private mutating func recordSpeed(to point: RouteCoordinate) {
            guard let previousPoint,
                  let previousTimestamp = previousPoint.timestamp,
                  let timestamp = point.timestamp else {
                return
            }
            let elapsed = timestamp.timeIntervalSince(previousTimestamp)
            guard elapsed > 0 else {
                return
            }
            let segmentMeters = RouteGeometry.distanceMeters(
                from: previousPoint.clCoordinate,
                to: point.clCoordinate
            )
            fastestMetersPerSecond = max(
                fastestMetersPerSecond,
                segmentMeters / elapsed
            )
        }
    }

    let pointCount: Int
    let startDate: Date?
    let endDate: Date?
    let duration: TimeInterval?
    let maxElevation: Measurement<UnitLength>?
    let minElevation: Measurement<UnitLength>?
    let elevationGain: Measurement<UnitLength>?
    let elevationLoss: Measurement<UnitLength>?
    let averageSpeed: Measurement<UnitSpeed>?
    let maxSpeed: Measurement<UnitSpeed>?

    init(distanceMeters: Double, route: [RouteCoordinate]) {
        var accumulator = Accumulator()
        for point in route {
            accumulator.consume(point)
        }
        self.init(
            distanceMeters: distanceMeters,
            pointCount: route.count,
            accumulator: accumulator
        )
    }

    static func cancellable(
        distanceMeters: Double,
        route: [RouteCoordinate]
    ) throws(CancellationError) -> Self {
        var accumulator = Accumulator()
        for (index, point) in route.enumerated() {
            if index.isMultiple(of: 255) {
                guard !Task.isCancelled else {
                    throw CancellationError()
                }
            }
            accumulator.consume(point)
        }
        guard !Task.isCancelled else {
            throw CancellationError()
        }
        return Self(
            distanceMeters: distanceMeters,
            pointCount: route.count,
            accumulator: accumulator
        )
    }

    private init(
        distanceMeters: Double,
        pointCount: Int,
        accumulator: Accumulator
    ) {
        self.pointCount = pointCount
        startDate = accumulator.firstTimestamp
        endDate = accumulator.lastTimestamp
        duration = accumulator.duration
        maxElevation = accumulator.maximumElevation.map { meters in
            Measurement(value: meters, unit: .meters)
        }
        minElevation = accumulator.minimumElevation.map { meters in
            Measurement(value: meters, unit: .meters)
        }
        if accumulator.elevationCount > 1 {
            elevationGain = Measurement(
                value: accumulator.gainMeters,
                unit: .meters
            )
            elevationLoss = Measurement(
                value: accumulator.lossMeters,
                unit: .meters
            )
        } else {
            elevationGain = nil
            elevationLoss = nil
        }
        averageSpeed = accumulator.duration.map { duration in
            Measurement(
                value: distanceMeters / duration,
                unit: .metersPerSecond
            )
        }
        maxSpeed = accumulator.fastestMetersPerSecond > 0
            ? Measurement(
                value: accumulator.fastestMetersPerSecond,
                unit: .metersPerSecond
            )
            : nil
    }
}

extension Hike {
    var pointCount: Int { route.count }

    private var routeStatistics: HikeRouteStatistics {
        HikeRouteStatistics(distanceMeters: distanceMeters, route: route)
    }

    var startDate: Date? { routeStatistics.startDate }
    var endDate: Date? { routeStatistics.endDate }

    /// Elapsed time between the first and last timestamped points.
    var duration: TimeInterval? { routeStatistics.duration }

    var maxElevation: Measurement<UnitLength>? { routeStatistics.maxElevation }

    var minElevation: Measurement<UnitLength>? { routeStatistics.minElevation }

    /// Cumulative climb over all points (sum of positive elevation deltas).
    var elevationGain: Measurement<UnitLength>? { routeStatistics.elevationGain }

    /// Cumulative descent over all points (sum of negative elevation deltas).
    var elevationLoss: Measurement<UnitLength>? { routeStatistics.elevationLoss }

    /// Distance ÷ moving time.
    var averageSpeed: Measurement<UnitSpeed>? { routeStatistics.averageSpeed }

    /// Fastest instantaneous pace between two consecutive timestamped points.
    var maxSpeed: Measurement<UnitSpeed>? { routeStatistics.maxSpeed }
}
