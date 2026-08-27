//
//  Hike+Statistics.swift
//  OpenHikes
//
//  Derived statistics computed from a Hike's route points.
//

import CoreLocation
import Foundation

/// Running elevation totals over a sequence of points: the extremes reached,
/// and the climb and descent between them, counted in runs rather than in
/// single steps so that sensor noise is not read as terrain.
///
/// Separate from the statistics that use it because three callers want exactly
/// this and nothing else — a hike's detail stats, the widget snapshot's summary
/// of a saved trail, and a recording's live gain — and "climbed" has to mean the
/// same thing in all three. That is also why the deadband lives here and not at
/// a call site: a recorded hike arrives barometrically smoothed and an imported
/// GPX arrives raw, and the two must still produce comparable numbers.
nonisolated struct ElevationAccumulator: Sendable {
    /// How far elevation has to reverse before the climb it interrupted is
    /// counted.
    ///
    /// Without one of these every sensor wobble is a hill. Noise is symmetric
    /// but summing `max(delta, 0)` is not, so jitter integrates in one
    /// direction forever: 2,000 points wandering ±1.5 m around a single
    /// elevation — a phone resting on a table — accumulate roughly 965 m of
    /// "climb". The error grows with the number of points, which means the
    /// longer the hike the more wrong the number, and it is never visibly
    /// wrong: 1,150 m on a 1,000 m climb reads like a plausible figure.
    ///
    /// Three metres is above the barometer's short-term noise floor and below
    /// anything a walker would call a rise, so real terrain passes through it
    /// unchanged — the fixture in `HikeStatisticsTests` reports the same
    /// +200/−60 with the deadband as without. It does not fully clean raw GPS
    /// altitude, which wanders by ±5–15 m; nothing at this layer can, because
    /// a 10 m spike is indistinguishable from a 10 m step. It bounds the
    /// damage to the amplitude of the noise instead of the amplitude times
    /// the point count, which is the difference between an overstatement and
    /// a fiction.
    static let reversalThresholdMeters = 3.0

    private(set) var count = 0
    private(set) var minimumMeters: Double?
    private(set) var maximumMeters: Double?

    /// A parameter only so tests can drive the deadband directly instead of
    /// inferring it; callers take the default, because "climbed" has to mean
    /// the same thing in all three of them.
    let reversalThresholdMeters: Double

    private var committedGain = 0.0
    private var committedLoss = 0.0

    /// The elevation the current run started from, and the furthest the run
    /// has reached. Everything between them is provisional: it counts toward
    /// the totals immediately but is not committed until the direction
    /// reverses far enough to prove the run is over.
    private var anchor: Double?
    private var extreme: Double?

    init(reversalThresholdMeters: Double = Self.reversalThresholdMeters) {
        self.reversalThresholdMeters = reversalThresholdMeters
    }

    /// Feeds one point's elevation in. A point without one is skipped rather
    /// than read as sea level, and it doesn't break the chain: the next height
    /// is compared against the last one that existed.
    mutating func record(_ elevation: Double?) {
        guard let elevation else { return }
        count += 1
        minimumMeters = min(minimumMeters ?? elevation, elevation)
        maximumMeters = max(maximumMeters ?? elevation, elevation)

        guard let runStart = anchor, let runPeak = extreme else {
            anchor = elevation
            extreme = elevation
            return
        }

        if runPeak >= runStart {
            // Climbing. A new high extends the run; anything short of the
            // threshold below the high is noise on the way up.
            if elevation > runPeak {
                extreme = elevation
            } else if runPeak - elevation >= reversalThresholdMeters {
                committedGain += runPeak - runStart
                anchor = runPeak
                extreme = elevation
            }
        } else {
            if elevation < runPeak {
                extreme = elevation
            } else if elevation - runPeak >= reversalThresholdMeters {
                committedLoss += runStart - runPeak
                anchor = runPeak
                extreme = elevation
            }
        }
    }

    /// Metres climbed, including the run in progress.
    ///
    /// The provisional run is included rather than withheld because a
    /// recording reads this live: a walker halfway up a climb has climbed,
    /// and a total that froze until they came back down would be wrong in a
    /// way the user can see. It also means no caller has to remember to
    /// finalise the accumulator when the route ends.
    var gainMeters: Double {
        guard let anchor, let extreme, extreme > anchor else { return committedGain }
        return committedGain + (extreme - anchor)
    }

    var lossMeters: Double {
        guard let anchor, let extreme, extreme < anchor else { return committedLoss }
        return committedLoss + (anchor - extreme)
    }

    /// Whether gain and loss mean anything yet. A single height is a position,
    /// not a change, and reporting "0 m climbed" for it would be a claim the
    /// data does not support.
    var hasChange: Bool { count > 1 }
}

/// What a route's elevations add up to, in the shape the widget snapshot
/// carries them.
nonisolated struct RouteElevationSummary: Sendable, Equatable {
    var lowMeters: Double?
    var highMeters: Double?
    var gainMeters: Double?
    var lossMeters: Double?

    init(_ accumulator: ElevationAccumulator) {
        lowMeters = accumulator.minimumMeters
        highMeters = accumulator.maximumMeters
        gainMeters = accumulator.hasChange ? accumulator.gainMeters : nil
        lossMeters = accumulator.hasChange ? accumulator.lossMeters : nil
    }
}

nonisolated struct HikeRouteStatistics: Sendable {
    private struct Accumulator {
        var firstTimestamp: Date?
        var lastTimestamp: Date?
        var elevation = ElevationAccumulator()
        var fastestMetersPerSecond = 0.0
        var inferredMeters = 0.0
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
            // Two consumers now want the same number, and for the caller that
            // doesn't have it lying around it costs trigonometry — so the
            // first one to ask pays and the second one doesn't.
            var measured: Double?
            let meters = {
                if let measured { return measured }
                let value = segmentMeters()
                measured = value
                return value
            }
            record(timestamp: point.timestamp)
            elevation.record(point.elevation)
            recordSpeed(to: point, segmentMeters: meters)
            recordInferred(to: point, segmentMeters: meters)
            previousPoint = point
        }

        private mutating func record(timestamp: Date?) {
            guard let timestamp else { return }
            if firstTimestamp == nil {
                firstTimestamp = timestamp
            }
            lastTimestamp = timestamp
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

        /// How much of the walked length crosses ground the recording never
        /// observed. ``RouteProvenance`` marks the segment arriving at a
        /// point, so the first point — which arrives from nowhere — is
        /// excluded by requiring a predecessor.
        private mutating func recordInferred(
            to point: RouteCoordinate,
            segmentMeters: () -> Double
        ) {
            guard previousPoint != nil, point.isInferred else { return }
            inferredMeters += segmentMeters()
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
    /// The part of the route that was reasoned about rather than measured, or
    /// `nil` when every segment came from a fix. See ``RouteProvenance``.
    let inferredDistance: Measurement<UnitLength>?

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
        maxElevation = accumulator.elevation.maximumMeters.map { meters in
            Measurement(value: meters, unit: .meters)
        }
        minElevation = accumulator.elevation.minimumMeters.map { meters in
            Measurement(value: meters, unit: .meters)
        }
        if accumulator.elevation.hasChange {
            elevationGain = Measurement(
                value: accumulator.elevation.gainMeters,
                unit: .meters
            )
            elevationLoss = Measurement(
                value: accumulator.elevation.lossMeters,
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
        inferredDistance = accumulator.inferredMeters > 0
            ? Measurement(value: accumulator.inferredMeters, unit: .meters)
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
