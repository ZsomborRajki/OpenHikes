//
//  RouteCarriedEnds.swift
//  OpenHikes
//
//  The ends of a line the hiker did not walk: the drive home a recording was
//  left running through, and the drive to the trailhead it was started
//  before. What *Edit Route* offers to take off in one tap.
//
//  ## What says a stretch was carried
//
//  Three things, any of which is enough for one leg:
//
//  - **Motion.** A recorded fix is tagged ``RouteMotion/nonPedestrian`` when
//    Core Motion called it driving or cycling. This is that tag's first
//    reader, and what it was kept for.
//  - **Speed.** Motion & Fitness can be refused, and an imported file has no
//    tag, so a leg covered faster than ``Policy/carriedMetersPerSecond`` is
//    carried too. That is past any pace on foot, and it needs the two fixes'
//    times.
//  - **A pause that moved.** With Auto-Pause on, a recording stopped at the
//    car stays paused while it is driven and takes up again on the walk to
//    the front door. Its drive is then no leg at all, only a pause whose two
//    ends are ``Policy/pauseJumpMeters`` apart, with a few steps after it.
//
//  ## Only the ends, and only a real stretch
//
//  A shuttle or a lift between two walked parts is in the middle, and is not
//  this type's to find. An end counts once ``Policy/minimumCarriedMeters`` of
//  it were carried, which a spike in a fix's position never adds up to, and
//  it runs back to the first carried leg with no more than
//  ``Policy/maximumFootGapMeters`` on foot at a time after it: a stop at a
//  junction, the steps from the car. A line with next to nothing walked on
//  it, a bicycle ride, has no ends to take off.
//
//  The thresholds are a first guess, to be changed from recordings that got
//  it wrong.
//

import CoreLocation
import Foundation

nonisolated public struct RouteCarriedEnds: Equatable, Sendable {
    /// One carried end.
    public struct Stretch: Equatable, Sendable {
        /// The part of the line it takes up, in metres along it.
        public let range: ClosedRange<Double>
        /// How far the hiker was carried over it, on the ground. More than
        /// the range's own length where a pause moved, since a paused leg has
        /// none (see ``RouteBoundary``).
        public let carriedMeters: Double

        public init(range: ClosedRange<Double>, carriedMeters: Double) {
            self.range = range
            self.carriedMeters = carriedMeters
        }
    }

    /// The thresholds — see the file header.
    public struct Policy: Equatable, Sendable {
        public var carriedMetersPerSecond = 6.0
        public var minimumCarriedMeters = 500.0
        public var maximumFootGapMeters = 200.0
        public var pauseJumpMeters = 1000.0
        /// How much has to be left between the two ends for them to be ends
        /// of a walk.
        public var minimumWalkMeters = 300.0

        public init() { /* the defaults above */ }
    }

    /// The carried stretch the line opens with, if it opens with one.
    public var leading: Stretch?
    /// The carried stretch the line closes with, if it closes with one.
    public var trailing: Stretch?

    public init(leading: Stretch? = nil, trailing: Stretch? = nil) {
        self.leading = leading
        self.trailing = trailing
    }

    public var isEmpty: Bool { leading == nil && trailing == nil }

    /// What is left of the line with both ends taken off, in metres along it.
    public func walkedRange(of totalMeters: Double) -> ClosedRange<Double> {
        let start = leading?.range.upperBound ?? 0
        let end = trailing?.range.lowerBound ?? totalMeters
        return start...max(start, end)
    }

    /// The carried ends of `route`.
    ///
    /// - Parameter distances: ``RouteTrim/distances(along:)`` of the same
    ///   route.
    public static func found(
        in route: [RouteCoordinate],
        distances: [Double],
        policy: Policy = Policy()
    ) -> Self {
        guard route.count > 1, distances.count == route.count, let total = distances.last else { return Self() }
        let legs = (1..<route.count).map { index in
            let meters = distances[index] - distances[index - 1]
            return Leg(from: route[index - 1], to: route[index], meters: meters, policy: policy)
        }
        let closing = carriedRun(of: legs.reversed(), policy: policy).map { run in
            // The run was counted from the line's end, so its last leg is the
            // earliest: leg `i` arrives at point `i + 1` and leaves point `i`.
            Stretch(range: distances[legs.count - run.legCount]...total, carriedMeters: run.carriedMeters)
        }
        let opening = carriedRun(of: legs, policy: policy).map { run in
            Stretch(range: 0...distances[run.legCount], carriedMeters: run.carriedMeters)
        }
        let ends = Self(leading: opening, trailing: closing)
        let walked = ends.walkedRange(of: total)
        guard walked.upperBound - walked.lowerBound >= policy.minimumWalkMeters else { return Self() }
        return ends
    }

    // MARK: Legs

    private struct Leg {
        /// Its length on the line's own axis, which is nothing for a pause.
        let meters: Double
        /// How far it carried the hiker, or `nil` for a leg walked.
        let carriedMeters: Double?

        init(from previous: RouteCoordinate, to point: RouteCoordinate, meters: Double, policy: Policy) {
            self.meters = meters
            if point.isPauseBoundary {
                let jump = RouteGeometry.distanceMeters(from: previous.clCoordinate, to: point.clCoordinate)
                carriedMeters = jump >= policy.pauseJumpMeters ? jump : nil
            } else if point.motion == .nonPedestrian || Self.isFast(from: previous, to: point, meters, policy) {
                carriedMeters = meters
            } else {
                carriedMeters = nil
            }
        }

        private static func isFast(
            from previous: RouteCoordinate,
            to point: RouteCoordinate,
            _ meters: Double,
            _ policy: Policy
        ) -> Bool {
            guard let began = previous.timestamp, let arrived = point.timestamp else { return false }
            let seconds = arrived.timeIntervalSince(began)
            return seconds > 0 && meters / seconds >= policy.carriedMetersPerSecond
        }
    }

    private struct Run {
        /// How many legs it takes up, counted from the end it was read from.
        var legCount: Int
        var carriedMeters: Double
    }

    /// The carried run `legs` open with: as far as the last carried leg that
    /// no more than a short walk separates from the one before it.
    private static func carriedRun(of legs: some Sequence<Leg>, policy: Policy) -> Run? {
        var run = Run(legCount: 0, carriedMeters: 0)
        var footGap = 0.0
        for (index, leg) in legs.enumerated() {
            if let carried = leg.carriedMeters {
                run.legCount = index + 1
                run.carriedMeters += carried
                footGap = 0
            } else {
                footGap += leg.meters
                if footGap > policy.maximumFootGapMeters { break }
            }
        }
        return run.carriedMeters >= policy.minimumCarriedMeters ? run : nil
    }
}
