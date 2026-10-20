//
//  GPXImport+Placeholders.swift
//  OpenHikes
//
//  Fixes a logger writes for "no fix", which Web Mercator can still draw.
//

import CoreLocation
import OpenHikesData

nonisolated extension GPXImport {
    /// How far a point must be from *both* neighbours to count as a teleport.
    static let teleportDistanceMeters = 100_000.0

    /// How close the two neighbours of a teleport must be to each other. A
    /// real leg between far-apart points has no such pair around it: the
    /// point before and the point after it are as far apart as the leg is.
    static let teleportNeighbourSpanMeters = 5000.0

    /// `points` without the placeholder fixes a logger writes for an epoch with
    /// no satellites.
    ///
    /// Two rules, and both drop rather than clamp, as ``point(_:)`` does for
    /// an unprojectable one: the neighbours are good geometry and the bad
    /// point is not.
    ///
    /// - Exactly `(0, 0)`: a drawable spot in the Gulf of Guinea, and what
    ///   plenty of loggers write when they have nothing. No trail is there.
    /// - A point far from both neighbours while those two are close to each
    ///   other — a median-of-three, which catches any other placeholder.
    ///   Judged against the neighbours as written, so two bad points in a row
    ///   are not repaired by this rule, and a point at either end of the
    ///   segment has only one neighbour and is left alone.
    static func droppingPlaceholders(from points: [Point]) -> [Point] {
        let located = points.filter { $0.coordinate.latitude != 0 || $0.coordinate.longitude != 0 }
        guard located.count > 2 else { return located }
        var kept = [located[0]]
        for index in 1..<(located.count - 1) {
            let before = located[index - 1].coordinate
            let here = located[index].coordinate
            let after = located[index + 1].coordinate
            let isolated = RouteGeometry.distanceMeters(from: before, to: here) > teleportDistanceMeters
                && RouteGeometry.distanceMeters(from: here, to: after) > teleportDistanceMeters
                && RouteGeometry.distanceMeters(from: before, to: after) < teleportNeighbourSpanMeters
            if !isolated { kept.append(located[index]) }
        }
        kept.append(located[located.count - 1])
        return kept
    }
}
