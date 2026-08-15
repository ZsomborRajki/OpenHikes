//
//  Hike+Statistics.swift
//  OpenHikes
//
//  Derived statistics computed from a Hike's route points.
//

import CoreLocation
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
                  lastTimestamp > firstTimestamp else { return nil }
            return lastTimestamp.timeIntervalSince(firstTimestamp)
        }

        /// - Parameter segmentMeters: distance from the previous point, or 0
        ///   for the first. A closure because the caller that already has the
        ///   number — ``RouteProfile``'s walk — should hand it over for free,
        ///   while the caller that doesn't shouldn't pay for the trigonometry
        ///   on the segments speed can't use anyway.
        mutating func consume(
            _ point: RouteCoordinate,
            segmentMeters: () -> Double
        ) {
            record(timestamp: point.timestamp)
            record(elevation: point.elevation)
            recordSpeed(to: point, segmentMeters: segmentMeters)
            previousPoint = point
        }

        private mutating func record(timestamp: Date?) {
            guard let timestamp else { return }
            if firstTimestamp == nil {
                firstTimestamp = timestamp
            }
            lastTimestamp = timestamp
        }

        private mutating func record(elevation: Double?) {
            guard let elevation else { return }
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

        private mutating func recordSpeed(
            to point: RouteCoordinate,
            segmentMeters: () -> Double
        ) {
            guard let previousPoint,
                  let previousTimestamp = previousPoint.timestamp,
                  let timestamp = point.timestamp else { return }
            let elapsed = timestamp.timeIntervalSince(previousTimestamp)
            guard elapsed > 0 else { return }
            fastestMetersPerSecond = max(
                fastestMetersPerSecond,
                segmentMeters() / elapsed
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

    /// Feeds the accumulator one point at a time, so a caller that is already
    /// walking the route can produce these statistics from that same pass.
    ///
    /// Opening a hike used to walk its route twice — once here and once in
    /// ``RouteProfile`` — and each walk computed its own per-segment
    /// distances, which is the expensive part. ``RouteProfile`` computes them
    /// unconditionally (they are its cumulative index), so it now drives this
    /// builder as it goes and the second walk is gone.
    struct Builder {
        private let distanceMeters: Double
        private var accumulator = Accumulator()
        private var pointCount = 0

        init(distanceMeters: Double) {
            self.distanceMeters = distanceMeters
        }

        /// - Parameter segmentMeters: distance from the previously consumed
        ///   point, or 0 for the first. Evaluated only for the segments that
        ///   can carry a speed — see ``Accumulator/consume(_:segmentMeters:)``.
        mutating func consume(
            _ point: RouteCoordinate,
            segmentMeters: @autoclosure () -> Double
        ) {
            pointCount += 1
            accumulator.consume(point, segmentMeters: segmentMeters)
        }

        consuming func finish() -> HikeRouteStatistics {
            HikeRouteStatistics(
                distanceMeters: distanceMeters,
                pointCount: pointCount,
                accumulator: accumulator
            )
        }
    }

    /// Walks `route` on its own, computing the per-segment distances it needs.
    ///
    /// The hike detail path goes through ``Builder`` instead, driven by the
    /// walk ``RouteProfile`` performs anyway; this is for callers with nothing
    /// else to walk for.
    init(distanceMeters: Double, route: [RouteCoordinate]) {
        var builder = Builder(distanceMeters: distanceMeters)
        var previous: CLLocationCoordinate2D?
        for point in route {
            let coordinate = point.clCoordinate
            let origin = previous
            previous = coordinate
            builder.consume(
                point,
                segmentMeters: origin.map { start in
                    RouteGeometry.distanceMeters(from: start, to: coordinate)
                } ?? 0
            )
        }
        self = builder.finish()
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

    /// Walks the route and derives every statistic — duration, gain and loss,
    /// the two speeds — from scratch, on the calling thread, on every read.
    ///
    /// The app's own numbers do not come through here: ``HikeDetailPreparation``
    /// drives ``HikeRouteStatistics/Builder`` off the main thread from the walk
    /// ``RouteProfile`` performs anyway. Don't read this from a SwiftUI body,
    /// and don't add per-stat wrappers around it — each one would repeat the
    /// walk.
    var routeStatistics: HikeRouteStatistics {
        HikeRouteStatistics(distanceMeters: distanceMeters, route: route)
    }
}
