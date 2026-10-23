//
//  Hike+Statistics.swift
//  OpenHikes
//
//  Derived statistics computed from a Hike's route points.
//

import CoreLocation
import DequeModule
import Foundation
import OpenHikesShared

/// How much of a route's clock the hiker spent moving, as opposed to standing
/// at a viewpoint, eating lunch, or waiting out a shower.
///
/// Derived from timestamps and coordinates alone, deliberately. The recording
/// pipeline knows a great deal more than that — Core Motion's verdict reaches
/// ``RecordingPointFlags/motionStationary``, and the live accumulator reads it
/// — but none of it survives into ``RouteCoordinate``, which carries a
/// position, a height, a time and two enums. So a recorded hike arrives here
/// knowing exactly what an imported GPX knows, and the alternative — a moving
/// average that exists for hikes this app recorded and is absent for the ones
/// the hiker brought with them — would be a worse answer than one rule that
/// works on both.
///
/// The rule itself is not a new one. ``RecordingDistanceAccumulator`` already
/// decides when a hiker has stopped, and does it exactly this way: a window
/// of ``RecordingDistanceAccumulator/stationaryInterval`` with less than
/// ``RecordingDistanceAccumulator/stationaryNetDisplacement`` of net
/// displacement across it is somebody standing still rather than somebody
/// walking. Those two constants are shared rather than copied, so the two
/// readings cannot drift. ``RecordingFixPolicy`` arrives at the same rate
/// independently — five metres inside ten seconds is the smallest movement it
/// will accept a fix for — which is some corroboration that half a metre per
/// second is where this app already draws the line.
///
/// The bias is deliberate and runs one way: **time counts as moving until the
/// window proves otherwise.** A window shorter than the interval has not seen
/// enough to judge, and says so by saying nothing. That costs accuracy on a
/// slow scramble, where a hiker genuinely under half a metre per second is
/// booked as stopped; the alternative bias costs much more, because a rule
/// that guesses "stopped" understates moving time and therefore *overstates*
/// the moving average — and the whole reason for a second row is that it is
/// the more flattering number. A flattering number that was guessed is worse
/// than no second row at all. Presuming movement means the failure mode is to
/// converge on the elapsed average, which is a number the app already stands
/// behind.
nonisolated public struct MovingTimeAccumulator: Sendable {
    /// The slowest a hiker can be going and still be walking, in metres per
    /// second, taken from the pair of constants above rather than declared.
    public static let stillnessRate =
        MovementThresholds.stationaryNetDisplacement
            / MovementThresholds.stationaryInterval

    private struct Sample {
        let timestamp: Date
        let coordinate: CLLocationCoordinate2D
    }

    /// The trailing window, trimmed so its first element is the newest sample
    /// that is still a full interval behind the latest one. Bounded by the
    /// window's length rather than the route's, so a 20,000-point import holds
    /// thirty-odd samples here, not twenty thousand.
    private var window: Deque<Sample> = []
    private var previous: Sample?

    public private(set) var seconds: TimeInterval = 0

    /// A sample that does not advance the clock is dropped whole — it is not
    /// measured, and it does not become the reference the next one measures
    /// against.
    ///
    /// The second half is the one that matters. A GPX with a timestamp out of
    /// order used to be rejected as an interval and accepted as a reference,
    /// so the sample after it was measured from the wrong place: `0, 100, 50,
    /// 200` booked 100 seconds and then another 150, which is 250 seconds of
    /// walking inside a 200-second hike. Holding the reference where it was
    /// makes that last interval the 100 seconds it really is, and keeps the
    /// window in the order ``trim(newest:)`` assumes it is in.
    public mutating func record(_ point: RouteCoordinate) {
        // A pause is not a stop this rule has to judge — the hiker declared
        // it. Neither the span it opened nor the displacement across it says
        // anything about walking, so the leg arriving here is dropped whole.
        // Without this a hiker who paused at the trailhead, drove to the next
        // one and resumed is credited with the whole drive as moving time,
        // because the rule sees only a long span and a large displacement and
        // calls that walking.
        //
        // Dropping the reference is the whole of it, and the point then falls
        // through to be recorded like any other. It is where the walking
        // starts again, so it has to become the baseline the next interval is
        // measured from — returning here instead would drop that interval too,
        // which is a second on a 1 Hz recording and minutes on a sparse
        // imported GPX.
        if point.isPauseBoundary {
            resetSegment()
        }
        guard let timestamp = point.timestamp else { return }
        let elapsed = previous.map { timestamp.timeIntervalSince($0.timestamp) }
        guard elapsed.map({ $0 > 0 }) ?? true else { return }
        let sample = Sample(timestamp: timestamp, coordinate: point.clCoordinate)
        previous = sample
        window.append(sample)
        trim(newest: timestamp)
        guard let elapsed, isMoving(at: sample) else { return }
        seconds += elapsed
    }

    /// Forgets what came before, keeping what has already been counted.
    ///
    /// Every measurement here is made *between* two samples, so a boundary the
    /// clock must not cross is expressed by dropping the reference and the
    /// window rather than by starting a new accumulator: the seconds already
    /// booked belong to the same walk and are still owed to the hiker.
    ///
    /// It drops the past and nothing else. The point that crosses the boundary
    /// is still recorded, and becomes the reference on the far side of it.
    public mutating func resetSegment() {
        window.removeAll(keepingCapacity: true)
        previous = nil
    }

    private mutating func trim(newest: Date) {
        while window.count > 1,
              newest.timeIntervalSince(window[1].timestamp)
                >= MovementThresholds.stationaryInterval {
            window.removeFirst()
        }
    }

    private func isMoving(at sample: Sample) -> Bool {
        guard let anchor = window.first else { return true }
        let span = sample.timestamp.timeIntervalSince(anchor.timestamp)
        // Net displacement, not distance walked: a hiker who spends four
        // minutes wandering ten metres around a bench has covered ground and
        // gone nowhere, which is the case this exists to catch.
        guard span >= MovementThresholds.stationaryInterval else { return true }
        let net = RouteGeometry.distanceMeters(
            from: anchor.coordinate,
            to: sample.coordinate
        )
        return net >= Self.stillnessRate * span
    }

    public init() {
        // Everything starts empty; see the stored defaults above.
    }
}

/// What a route's elevations add up to, in the shape the widget snapshot
/// carries them.
nonisolated public struct RouteElevationSummary: Sendable, Equatable {
    public var lowMeters: Double?
    public var highMeters: Double?
    public var gainMeters: Double?
    public var lossMeters: Double?

    public init(_ accumulator: ElevationAccumulator) {
        lowMeters = accumulator.minimumMeters
        highMeters = accumulator.maximumMeters
        gainMeters = accumulator.hasChange ? accumulator.gainMeters : nil
        lossMeters = accumulator.hasChange ? accumulator.lossMeters : nil
    }
}

nonisolated public struct HikeRouteStatistics: Sendable {
    private struct Accumulator {
        var firstTimestamp: Date?
        var lastTimestamp: Date?
        var elevation = ElevationAccumulator()
        var movingTime = MovingTimeAccumulator()
        var fastestMetersPerSecond = 0.0
        var inferredMeters = 0.0
        private var walkedMeters = 0.0
        private var timedMeters = 0.0
        /// Metres walked since the last stamped point, held until a later
        /// stamp claims them. Whatever is left here when the route ends is
        /// the untimed tail, and is never claimed.
        private var pendingMeters = 0.0
        var previousPoint: RouteCoordinate?

        var duration: TimeInterval? {
            guard let firstTimestamp,
                  let lastTimestamp,
                  lastTimestamp > firstTimestamp else { return nil }
            return lastTimestamp.timeIntervalSince(firstTimestamp)
        }

        /// The share of the walked length that lies between the first and the
        /// last stamped point — the only stretch ``duration`` is a clock for.
        ///
        /// A partly stamped GPX otherwise divides a whole route by part of a
        /// walk: ten kilometres with a clock on the last two report the pace
        /// of a runner. Cutting the distance by this keeps the numerator and
        /// the denominator describing the same ground.
        ///
        /// It is exactly 1 — and so exactly the number this app has always
        /// reported — for a route stamped throughout, and also for one that
        /// loses its stamps only in the middle, where the elapsed clock spans
        /// the gap regardless.
        var timedDistanceFraction: Double {
            guard walkedMeters > 0 else { return 1 }
            return min(timedMeters / walkedMeters, 1)
        }

        /// - Parameter segmentMeters: distance from the previous point, or 0
        ///   for the first. A closure because the caller that already has the
        ///   number — ``RouteProfile``'s walk — should hand it over for free.
        ///   It is read once per point rather than only for the segments that
        ///   carry a speed: timestamp coverage counts every metre, including
        ///   the ones no clock reaches.
        mutating func consume(
            _ point: RouteCoordinate,
            segmentMeters: () -> Double
        ) {
            let meters = segmentMeters()
            // Before the timestamp is recorded, so that the segment arriving
            // at the first stamped point is still outside the clock.
            recordCoverage(point, segmentMeters: meters)
            record(timestamp: point.timestamp)
            elevation.record(point)
            movingTime.record(point)
            recordSpeed(to: point, segmentMeters: meters)
            recordInferred(to: point, segmentMeters: meters)
            previousPoint = point
        }

        /// Books the segment against the walked length, and against the timed
        /// length once the clock has reached it.
        ///
        /// Metres between two stamped points count even when the points
        /// between them carry no stamp — the elapsed clock spans them either
        /// way — so they wait in `pendingMeters` for the next stamp to claim
        /// them. Metres before the first stamp are never pending, and the ones
        /// after the last stamp are pending forever, which is how a leading
        /// and a trailing untimed stretch both fall out of the total.
        private mutating func recordCoverage(
            _ point: RouteCoordinate,
            segmentMeters meters: Double
        ) {
            walkedMeters += meters
            if firstTimestamp != nil { pendingMeters += meters }
            guard point.timestamp != nil else { return }
            timedMeters += pendingMeters
            pendingMeters = 0
        }

        private mutating func record(timestamp: Date?) {
            guard let timestamp else { return }
            if firstTimestamp == nil {
                firstTimestamp = timestamp
            }
            lastTimestamp = timestamp
        }

        /// The fastest segment the route can support — which is not the same
        /// as the fastest one it contains.
        ///
        /// A recorded route arrives here already filtered: ``RecordingFixPolicy``
        /// refuses a fix whose implied speed is past its own
        /// ``RecordingFixPolicy/maximumSpeed`` unless something corroborates
        /// it. An imported GPX is filtered by nobody, so a single noisy pair a
        /// second apart and a hundred metres wide reports ~360 km/h as the
        /// walk's maximum — wrong, and the largest number on the screen.
        ///
        /// The segment is discarded rather than capped. Capping would report
        /// exactly the ceiling, which is a second invented number wearing the
        /// same clothes as a measurement; discarding leaves the fastest
        /// segment that is actually walkable, and a route with none reports no
        /// maximum at all — the answer this already gives a walk with no clock.
        /// It also means a leg spent on a chairlift stops being the headline
        /// figure for the hike around it.
        ///
        /// Shares the recording path's threshold rather than declaring a
        /// second one, so "faster than a person moves on foot" means one thing
        /// across the app.
        private mutating func recordSpeed(
            to point: RouteCoordinate,
            segmentMeters meters: Double
        ) {
            // A pause leg has a length and a span but no walk between them, so
            // dividing one by the other measures the hiker's lunch break.
            guard !point.isPauseBoundary,
                  let previousPoint,
                  let previousTimestamp = previousPoint.timestamp,
                  let timestamp = point.timestamp else { return }
            let elapsed = timestamp.timeIntervalSince(previousTimestamp)
            guard elapsed > 0 else { return }
            let speed = meters / elapsed
            guard speed <= MovementThresholds.maximumOnFootSpeed else { return }
            fastestMetersPerSecond = max(fastestMetersPerSecond, speed)
        }

        /// How much of the walked length crosses ground the recording never
        /// observed. ``RouteProvenance`` marks the segment arriving at a
        /// point, so the first point — which arrives from nowhere — is
        /// excluded by requiring a predecessor.
        private mutating func recordInferred(
            to point: RouteCoordinate,
            segmentMeters meters: Double
        ) {
            guard previousPoint != nil, point.isInferred else { return }
            inferredMeters += meters
        }
    }

    public let pointCount: Int
    public let startDate: Date?
    public let endDate: Date?
    public let duration: TimeInterval?
    /// The part of ``duration`` the hiker spent moving — see
    /// ``MovingTimeAccumulator``. `nil` when the route carries no clock, and
    /// also when the rule was able to judge every window in it and called them
    /// all stops, which is what a stationary recording's own sparse fixes look
    /// like.
    public let movingDuration: TimeInterval?
    public let maxElevation: Measurement<UnitLength>?
    public let minElevation: Measurement<UnitLength>?
    public let elevationGain: Measurement<UnitLength>?
    public let elevationLoss: Measurement<UnitLength>?
    /// Distance over the whole clock, lunch and all. Kept exactly as it was:
    /// it is what every hike this app has already saved reports, and quietly
    /// redefining it would rewrite the history of walks nobody re-recorded.
    ///
    /// The distance is the part of the route the clock actually covers — all
    /// of it for a route stamped throughout, less for a GPX whose stamps start
    /// late or stop early. See ``Accumulator/timedDistanceFraction``.
    public let averageSpeed: Measurement<UnitSpeed>?
    /// The same distance over ``movingDuration`` instead. Always at least
    /// ``averageSpeed``, and equal to it for a walk with no stop long enough
    /// to see.
    public let movingAverageSpeed: Measurement<UnitSpeed>?
    public let maxSpeed: Measurement<UnitSpeed>?
    /// The part of the route that was reasoned about rather than measured, or
    /// `nil` when every segment came from a fix. See ``RouteProvenance``.
    public let inferredDistance: Measurement<UnitLength>?

    /// Feeds the accumulator one point at a time, so a caller that is already
    /// walking the route can produce these statistics from that same pass.
    ///
    /// Opening a hike used to walk its route twice — once here and once in
    /// ``RouteProfile`` — and each walk computed its own per-segment
    /// distances, which is the expensive part. ``RouteProfile`` computes them
    /// unconditionally (they are its cumulative index), so it now drives this
    /// builder as it goes and the second walk is gone.
    public struct Builder {
        private let distanceMeters: Double
        private var accumulator = Accumulator()
        private var pointCount = 0

        public init(distanceMeters: Double) {
            self.distanceMeters = distanceMeters
        }

        /// - Parameter segmentMeters: distance from the previously consumed
        ///   point, or 0 for the first. Evaluated once per point — see
        ///   ``Accumulator/consume(_:segmentMeters:)``.
        public mutating func consume(
            _ point: RouteCoordinate,
            segmentMeters: @autoclosure () -> Double
        ) {
            pointCount += 1
            accumulator.consume(point, segmentMeters: segmentMeters)
        }

        public consuming func finish() -> HikeRouteStatistics {
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
    /// else to walk for. Its legs are measured by the same rule —
    /// ``RouteCoordinate/legMeters(from:)``, which gives a paused leg no
    /// length — so the two paths agree.
    public init(distanceMeters: Double, route: [RouteCoordinate]) {
        var builder = Builder(distanceMeters: distanceMeters)
        var previous: RouteCoordinate?
        for point in route {
            let origin = previous
            previous = point
            builder.consume(point, segmentMeters: origin.map(point.legMeters(from:)) ?? 0)
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
        // Divided into the same distance the row above it uses, rather than
        // into the metres the moving windows happened to contain: the two rows
        // are the one distance seen through two clocks, and a hiker who found
        // them disagreeing about how far they went would be right to stop
        // believing either.
        // Moving time is a part of the elapsed clock, so it is reported only
        // alongside one and never longer than one. The accumulator refuses to
        // measure backwards, but a route whose last timestamp precedes its own
        // high-water mark still ends earlier than it walked, and the row would
        // otherwise claim more movement than the hike lasted.
        movingDuration = accumulator.duration.flatMap { duration in
            let moving = min(accumulator.movingTime.seconds, duration)
            return moving > 0 ? moving : nil
        }
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
        // Both clocks measure the stretch between the first and the last
        // stamped point, so both are divided into the length of that stretch
        // rather than the length of the whole route. For a route stamped
        // throughout — every hike this app has recorded — the cut is the whole
        // route and neither number moves. See
        // ``Accumulator/timedDistanceFraction``.
        let timedDistanceMeters = distanceMeters * accumulator.timedDistanceFraction
        averageSpeed = accumulator.duration.map { duration in
            Measurement(
                value: timedDistanceMeters / duration,
                unit: .metersPerSecond
            )
        }
        movingAverageSpeed = movingDuration.map { moving in
            Measurement(
                value: timedDistanceMeters / moving,
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

public extension Hike {
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
