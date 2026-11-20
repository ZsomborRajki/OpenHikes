//
//  RouteShape.swift
//  OpenHikesData
//
//  Whether a walked line is a loop, goes out and comes back the way it went,
//  or ends somewhere else.
//
//  A recording is named for it (the app's `RecordingTitle`), and the word is
//  only worth having when it is right: "Malerwinkel Loop" on a walk that went
//  up a gorge and came back down it is a name the hiker has to delete. So two
//  ends that meet are not enough, which is all a curated trail's shape asks
//  (the app's `TrailShape`): that one is read off a trail's own line, drawn
//  once, and a walk can come back along the ground it went out on.
//
//  ## Halves, not a turnaround
//
//  A walk that goes out and back turns round at the middle of its length,
//  wherever that is on the map. So the second half of the line is laid over
//  the first, and the walk is out and back when at least half of that second
//  half runs along ground the first half covered. The farthest point from
//  the start is not asked for: a path that bends back on itself is farthest
//  at the bend, kilometers before the walk turns round.
//
//  Half, because a loop often shares its way in and out. A loop with a short
//  path to it from the car park is still a loop, and a long path to a small
//  loop at its end is there and back.
//
//  ## Ground, not points
//
//  Both halves are sampled at one spacing along their length, so a stretch
//  recorded once a second and one recorded every 25 meters weigh what they
//  measure. The first half's samples are filed in a grid of cells twice the
//  spacing across, and a sample of the second half is on covered ground when
//  its cell, or one beside it, holds any: within one cell at the nearest and
//  under three at the farthest, which takes in two passes along one path
//  under trees and leaves out a path on the other side of a stream.
//
//  ## A pause that moved the walk
//
//  A pause is not distance and not trail (`RouteBoundary`), and a hiker can
//  be carried a long way inside one: down by the cable car, or back to the
//  start in a shuttle. Read as one line, such a walk comes back by the
//  straight leg across the pause, and two stretches walked away from each
//  other would be called a loop. So a line is handed over with the legs its
//  pauses opened, and a walk one of them moved further than a line's two
//  ends may be apart has no shape at all: nothing it walked is known to
//  close. A pause the hiker stood still through, for lunch or for a stop
//  Auto-Pause made, leaves a leg shorter than that, and the walk is read
//  whole.
//

import CoreLocation
import Foundation
import OpenHikesShared

/// What kind of line a walk drew.
nonisolated public enum RouteShape: Hashable, Sendable {
    /// Ends where it began, by other ground than it set out on.
    case loop
    /// Ends where it began, the way it came.
    case outAndBack
    /// Ends somewhere else.
    case pointToPoint

    /// The leg a pause opened: from the last point before it to the first
    /// after it.
    public struct PausedLeg: Sendable {
        public var from: CLLocationCoordinate2D
        public var to: CLLocationCoordinate2D

        public init(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) {
            self.from = from
            self.to = to
        }

        /// Whether the walk went on from about where it stopped — no further
        /// than ``RouteShape/closingToleranceMeters``, the gap two ends of a
        /// loop may leave. A leg that cannot be measured has not shown that
        /// it did.
        var keepsTheWalkInPlace: Bool {
            RouteGeometry.distanceMeters(from: from, to: to) <= RouteShape.closingToleranceMeters
        }
    }

    /// How far apart a line's two ends may be for it to have come back.
    ///
    /// The figure a curated trail's shape is read by, for one answer to one
    /// question: a hiker who stops the recording at the car, across the car
    /// park from where it was started, has walked a loop.
    public static let closingToleranceMeters: Double = 150
    /// The share of the way back that has to run along the way out for the
    /// walk to be out and back.
    static let retracedShare = 0.5
    /// How far apart the samples along the line are, where the line is short
    /// enough to afford it.
    static let sampleSpacingMeters: Double = 10
    /// The most samples one line is cut into. Past it the spacing grows, so a
    /// line of any length costs the same.
    static let maximumSamples = 20_000
    /// A cell of the grid, in spacings: wide enough that two samples one
    /// spacing apart are never further than a cell from each other.
    private static let cellSpacings: Double = 2

    /// The shape of a saved route, with the legs its pauses opened — see
    /// ``of(_:pausedLegs:)``.
    public static func of(route: [RouteCoordinate]) -> Self? {
        of(
            route.map(\.clCoordinate),
            pausedLegs: route.trailRuns.pausedLegs.map { leg in
                PausedLeg(from: route[leg].clCoordinate, to: route[leg + 1].clCoordinate)
            }
        )
    }

    /// The shape of the line through `coordinates`, or `nil` for a line too
    /// slight to have one: fewer than two points, or one that never went
    /// further from its start than ``closingToleranceMeters``.
    ///
    /// - Parameter pausedLegs: The legs of the line its pauses opened. One
    ///   that moved the walk leaves it no shape — see *A pause that moved
    ///   the walk* above.
    public static func of(
        _ coordinates: [CLLocationCoordinate2D],
        pausedLegs: [PausedLeg] = []
    ) -> Self? {
        guard let start = coordinates.first, let end = coordinates.last, coordinates.count > 1,
              pausedLegs.allSatisfy(\.keepsTheWalkInPlace) else {
            return nil
        }
        let gap = RouteGeometry.distanceMeters(from: start, to: end)
        // A coordinate that is not a number measures as one, and says nothing.
        guard gap.isFinite else { return nil }
        guard gap <= closingToleranceMeters else { return .pointToPoint }
        let line = coordinates
            .map { RouteGeometry.localOffset(from: start, to: $0) }
            .filter { $0.x.isFinite && $0.y.isFinite }
        let reach = line.reduce(0) { max($0, hypot($1.x, $1.y)) }
        guard reach > closingToleranceMeters else { return nil }

        let length = zip(line, line.dropFirst()).reduce(0) { total, leg in
            total + hypot(leg.1.x - leg.0.x, leg.1.y - leg.0.y)
        }
        let spacing = max(sampleSpacingMeters, length / Double(maximumSamples))
        let samples = samples(along: line, every: spacing)
        let wayOut = samples.prefix(samples.count / 2)
        let wayBack = samples.dropFirst(samples.count / 2)
        guard !wayBack.isEmpty else { return nil }

        let cellSize = spacing * cellSpacings
        let covered = Set(wayOut.map { Cell($0, size: cellSize) })
        let retraced = wayBack.count { Cell($0, size: cellSize).neighborhood.contains(where: covered.contains) }
        return Double(retraced) >= Double(wayBack.count) * retracedShare ? .outAndBack : .loop
    }

    /// One point every `spacing` meters of the line's own length, its first
    /// included.
    private static func samples(
        along line: [(x: Double, y: Double)],
        every spacing: Double
    ) -> [(x: Double, y: Double)] {
        guard let first = line.first else { return [] }
        var samples = [first]
        // How far along the leg in hand the next sample falls.
        var untilNext = spacing
        for (from, to) in zip(line, line.dropFirst()) {
            let legLength = hypot(to.x - from.x, to.y - from.y)
            guard legLength > 0 else { continue }
            while untilNext <= legLength {
                let fraction = untilNext / legLength
                samples.append((
                    x: from.x + (to.x - from.x) * fraction,
                    y: from.y + (to.y - from.y) * fraction
                ))
                untilNext += spacing
            }
            untilNext -= legLength
        }
        return samples
    }

    /// One square of the grid the way out is filed in.
    private struct Cell: Hashable {
        let column: Int
        let row: Int

        init(column: Int, row: Int) {
            self.column = column
            self.row = row
        }

        init(_ point: (x: Double, y: Double), size: Double) {
            self.init(column: Int((point.x / size).rounded(.down)), row: Int((point.y / size).rounded(.down)))
        }

        /// This cell and the eight around it.
        var neighborhood: [Self] {
            (-1...1).flatMap { columnStep in
                (-1...1).map { rowStep in Self(column: column + columnStep, row: row + rowStep) }
            }
        }
    }
}
