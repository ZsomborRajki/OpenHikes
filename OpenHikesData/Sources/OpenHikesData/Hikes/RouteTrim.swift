//
//  RouteTrim.swift
//  OpenHikes
//
//  A line with its ends cut off: what *Edit Route* keeps of a hike when the
//  hiker drags its start or its end inward, or takes off the drive a
//  recording was left running through.
//
//  ## What a trim keeps
//
//  Every point between the two cuts, exactly as it was saved: its position,
//  its height, its time, what it was inferred from and where the recording
//  paused. A trim re-routes nothing and guesses nothing, which is what lets
//  it be offered on a line somebody walked.
//
//  ## Where a cut falls
//
//  In metres along the line, on the axis ``RouteProfile`` measures: a leg a
//  pause opened has no length there (see ``RouteBoundary``). A cut between
//  two points makes a point of its own on the leg between them, with the
//  height and the time of that spot read off its two ends, so a line of
//  sparse points — an import, a drawn trail's straight leg — is cut where the
//  hiker put the handle rather than at whichever point was nearest. A cut
//  within ``snapMeters`` of a point takes that point instead, so dragging a
//  handle back to where it was gives the line it was.
//
//  ## A pause at a cut
//
//  The two fixes either side of a pause stand at one distance. A line cut
//  there ends on the fix before the pause, or begins on the fix after it:
//  never with the pause itself, which would be a leg leading nowhere.
//
//  Except at the line's own two ends, where a cut standing there is an end
//  left alone and keeps every point. A recording paused through the drive
//  home and stopped on the first fix after it ends on a pause with nothing
//  walked past it, so the drive stands right on the end: the walk is the
//  whole of the line's length, and only ``EndPauses`` can say to take that
//  fix off.
//

import Algorithms
import CoreLocation
import Foundation

nonisolated public enum RouteTrim {
    /// How near a cut may come to a point of the line and take that point
    /// rather than make one beside it.
    public static let snapMeters = 0.5

    /// The ends of a line at which a cut standing on the end itself takes
    /// off the pause there, as a cut anywhere else does — see *A pause at a
    /// cut* in the file header.
    public struct EndPauses: OptionSet, Hashable, Sendable {
        public let rawValue: Int

        public init(rawValue: Int) {
            self.rawValue = rawValue
        }

        /// The line begins on the fix after the pause it opens with.
        public static let start = Self(rawValue: 1 << 0)
        /// The line ends on the fix before the pause it closes with.
        public static let end = Self(rawValue: 1 << 1)
    }

    /// How far along `route` each of its points stands, in metres, by the
    /// rule ``RouteProfile/distances`` follows: one figure a point, ascending,
    /// with nothing added for a leg a pause opened.
    public static func distances(along route: [RouteCoordinate]) -> [Double] {
        var distances: [Double] = []
        distances.reserveCapacity(route.count)
        var cumulative = 0.0
        var previous: RouteCoordinate?
        for point in route {
            cumulative += previous.map(point.legMeters(from:)) ?? 0
            distances.append(cumulative)
            previous = point
        }
        return distances
    }

    /// The part of `route` between two distances along it — see the file
    /// header for what it keeps and where a cut falls.
    ///
    /// - Parameter distances: ``distances(along:)`` of the same route, handed
    ///   in because every caller has measured the line already.
    /// - Parameter pauses: the ends where a cut standing on the end takes off
    ///   the pause there.
    /// - Returns: the kept line, or nothing when the two cuts leave less than
    ///   a line: fewer than two points, or no length.
    public static func trimmed(
        _ route: [RouteCoordinate],
        distances: [Double],
        keeping range: ClosedRange<Double>,
        takingOff pauses: EndPauses = []
    ) -> [RouteCoordinate] {
        guard route.count > 1, distances.count == route.count, let total = distances.last else { return [] }
        let start = min(max(range.lowerBound, 0), total)
        let end = min(max(range.upperBound, 0), total)
        guard end > start else { return [] }

        let head = startCut(of: route, distances: distances, at: start, isCut: start > 0 || pauses.contains(.start))
        let tail = endCut(of: route, distances: distances, at: end, isCut: end < total || pauses.contains(.end))
        var kept: [RouteCoordinate] = []
        if let made = head.made { kept.append(made) }
        if head.firstWhole <= tail.lastWhole {
            kept.append(contentsOf: route[head.firstWhole...tail.lastWhole])
        }
        if let made = tail.made { kept.append(made) }
        guard kept.count > 1 else { return [] }
        // Nothing arrives at the first point of a line, so a new one names
        // neither a pause nor an inference: both describe the leg leading to
        // it. The line's own first point is left as it was saved.
        if head.made != nil || head.firstWhole > 0 {
            kept[0].boundary = nil
            kept[0].provenance = nil
        }
        return kept
    }

    /// The same, measuring the line first.
    public static func trimmed(
        _ route: [RouteCoordinate],
        keeping range: ClosedRange<Double>,
        takingOff pauses: EndPauses = []
    ) -> [RouteCoordinate] {
        trimmed(route, distances: distances(along: route), keeping: range, takingOff: pauses)
    }

    /// How long `route` was being recorded: the gaps between its stamped
    /// points, with every gap a pause opened left out. The figure a
    /// recording's own walk is measured by, read off a saved line — see
    /// `PreparedRecording.recordedSeconds` for why it is the points and not
    /// the clock.
    ///
    /// Points with no time between two that have one are inside the gap, not
    /// the end of it: a stretch drawn along another path (``RouteStep``) has
    /// none, and the hiker was walking for as long as it took to cross.
    public static func recordedSeconds(of route: [RouteCoordinate]) -> TimeInterval {
        var total = 0.0
        var began: Date?
        var isPaused = false
        for point in route {
            if point.isPauseBoundary { isPaused = true }
            guard let arrived = point.timestamp else { continue }
            if let began, !isPaused, arrived > began { total += arrived.timeIntervalSince(began) }
            began = arrived
            isPaused = false
        }
        return total
    }

    // MARK: The two cuts

    private struct StartCut {
        /// The point the cut made, when it fell between two.
        var made: RouteCoordinate?
        var firstWhole: Int
    }

    private struct EndCut {
        var lastWhole: Int
        var made: RouteCoordinate?
    }

    /// Where the kept line begins. `start` is short of the line's end, so a
    /// point stands past it.
    ///
    /// - Parameter isCut: `false` for an end left alone, which keeps every
    ///   point it had, a pause on it included.
    private static func startCut(
        of route: [RouteCoordinate],
        distances: [Double],
        at start: Double,
        isCut: Bool
    ) -> StartCut {
        guard isCut else { return StartCut(firstWhole: 0) }
        // The first point past the cut. Every point at the cut's own distance
        // is before it, so across a pause the one taken is the fix after it.
        let upper = min(distances.partitioningIndex { $0 > start }, route.count - 1)
        let lower = max(upper - 1, 0)
        if start - distances[lower] <= snapMeters { return StartCut(firstWhole: lower) }
        if distances[upper] - start <= snapMeters { return StartCut(firstWhole: upper) }
        return StartCut(
            made: point(at: start, between: lower, and: upper, of: route, distances: distances),
            firstWhole: upper
        )
    }

    /// Where the kept line ends. `end` is past the line's start, so a point
    /// stands before it.
    private static func endCut(
        of route: [RouteCoordinate],
        distances: [Double],
        at end: Double,
        isCut: Bool
    ) -> EndCut {
        guard isCut else { return EndCut(lastWhole: route.count - 1) }
        // The first point at or past the cut. Of the points at the cut's own
        // distance it is the first, so across a pause the one taken is the
        // fix before it.
        let upper = min(distances.partitioningIndex { $0 >= end }, route.count - 1)
        let lower = max(upper - 1, 0)
        if distances[upper] - end <= snapMeters { return EndCut(lastWhole: upper) }
        if end - distances[lower] <= snapMeters { return EndCut(lastWhole: lower) }
        return EndCut(
            lastWhole: lower,
            made: point(at: end, between: lower, and: upper, of: route, distances: distances)
        )
    }

    /// The spot `target` metres along the line, on the leg between two of its
    /// points: its height and its time read off the leg's two ends, and what
    /// the leg was — carried, inferred — off the point it arrives at, which is
    /// the end that says so (see ``RouteProvenance``).
    private static func point(
        at target: Double,
        between lower: Int,
        and upper: Int,
        of route: [RouteCoordinate],
        distances: [Double]
    ) -> RouteCoordinate {
        let from = route[lower]
        let to = route[upper]
        let length = distances[upper] - distances[lower]
        let fraction = length > 0 ? (target - distances[lower]) / length : 0
        let coordinate = RouteGeometry.interpolate(from: from.clCoordinate, to: to.clCoordinate, fraction: fraction)
        var elevation: Double?
        if let low = from.elevation, let high = to.elevation, low.isFinite, high.isFinite {
            elevation = low + (high - low) * fraction
        }
        var timestamp: Date?
        if let began = from.timestamp, let arrived = to.timestamp {
            timestamp = began.addingTimeInterval(arrived.timeIntervalSince(began) * fraction)
        }
        return RouteCoordinate(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            elevation: elevation,
            timestamp: timestamp,
            motion: to.motion,
            provenance: to.provenance
        )
    }
}
