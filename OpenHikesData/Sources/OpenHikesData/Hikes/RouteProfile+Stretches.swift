//
//  RouteProfile+Stretches.swift
//  OpenHikesData
//
//  A walk's covered distances, as lines a map can draw.
//
//  Coverage is a set of ranges on the profile's axis, and on that axis a pause
//  is a single distance: the leg it opened has no length (see
//  `RouteBoundary`). So a walk that went right up to a pause and carried on
//  after it covers one unbroken range — and a line drawn through every route
//  point inside it would run straight across the drive between the two
//  pieces, which nobody walked and the walk never matched (#962). This splits
//  the line where the route does.
//

import Algorithms
import CoreLocation
import Foundation

nonisolated public extension RouteProfile {
    /// The route between two distances, as one line per recorded piece: every
    /// route point inside the range, with the range's own ends interpolated
    /// onto the route so a stretch starts and stops where the coverage did
    /// rather than at the nearest track point. Empty for a range with no
    /// length.
    ///
    /// The start is read off the leg the range starts on rather than from
    /// ``coordinate(atDistance:)``, which at a pause's own distance answers
    /// the fix *before* the pause: a range starting there starts on the piece
    /// after it.
    ///
    /// The end is clamped to the route's length, so a range stored on a
    /// longer axis stops where the line does. Unclamped, it would take in
    /// every point to the last one, and on a route that ends on a pause that
    /// is the lone fix across the drive.
    func stretches(covering range: ClosedRange<Double>) -> [[CLLocationCoordinate2D]] {
        let upper = min(range.upperBound, totalDistanceMeters)
        guard upper > range.lowerBound,
              let end = coordinate(atDistance: upper)
        else { return [] }
        let first = distances.partitioningIndex { $0 > range.lowerBound }
        let last = distances.partitioningIndex { $0 >= upper }
        guard let start = start(of: range.lowerBound, onLegArrivingAt: first) else { return [] }

        // Neither end's own leg can be a pause — a paused leg has no length,
        // so no range bound falls strictly inside it — so a pause can only
        // lie between two of the points in the middle.
        var pieces: [[CLLocationCoordinate2D]] = []
        var piece: [CLLocationCoordinate2D] = [start]
        for index in first..<max(first, last) {
            if index > first, pausedSegments.contains(index - 1) {
                pieces.append(piece)
                piece = []
            }
            piece.append(coordinates[index])
        }
        piece.append(end)
        pieces.append(piece)
        return pieces.filter { $0.count > 1 }
    }

    /// Where a range starting at `distance` begins: on the leg arriving at
    /// `index`, the first point past it.
    private func start(of distance: Double, onLegArrivingAt index: Int) -> CLLocationCoordinate2D? {
        guard index > 0, index < coordinates.count else { return coordinate(atDistance: distance) }
        let length = distances[index] - distances[index - 1]
        guard length > 0 else { return coordinates[index] }
        return RouteGeometry.interpolate(
            from: coordinates[index - 1],
            to: coordinates[index],
            fraction: (distance - distances[index - 1]) / length
        )
    }
}
