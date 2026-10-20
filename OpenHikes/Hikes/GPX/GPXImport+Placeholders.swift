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

    /// How close the two neighbours of a teleport must be to each other.
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
    /// - In a recorded track, a point far from both neighbours while those
    ///   two are close to each other — a median-of-three for other placeholders.
    ///   Judged against the neighbours as written, so two bad points in a row
    ///   are not repaired by this rule, and a point at either end of the
    ///   segment has only one neighbour and is left alone.
    ///
    /// Planned routes and waypoint-only files can use widely spaced stops
    /// for a real out-and-back, so only the exact origin check applies to them.
    static func droppingPlaceholders(from points: [Point], isRecordedTrack: Bool) -> [Point] {
        let located = points.filter { $0.coordinate.latitude != 0 || $0.coordinate.longitude != 0 }
        guard isRecordedTrack, located.count > 2 else { return located }
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
