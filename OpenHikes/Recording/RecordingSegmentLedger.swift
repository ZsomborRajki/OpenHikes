//
//  RecordingSegmentLedger.swift
//  OpenHikes
//
//  The segments a recording's pauses have cut it into so far (#1470).
//
//  A saved hike's segments are read off its route (``RouteSegments``). A
//  recording has no route until Stop, so this feeds the same builder the
//  route's points as they are kept, and reads it as the saved hike will be
//  read: the same runs, the same lone fixes left out, the same stops, the
//  same climb, the same cap on how many, and the recording's distance shared
//  out over the segments by their lines as the saved distance is. A second
//  set of rules here, from running totals, read the same walk differently
//  in each of those, and a hiker who watched one figure during the walk and
//  found another on the saved hike would be right to believe neither.
//
//  Fed from ``RecordingDistanceAccumulator/append(_:)``, the one place every
//  kept fix passes through exactly once, live and on the replay that rebuilds
//  state from the journal. So an auto-pause that takes a stop's first minutes
//  back out of the journal takes them out of the segments by the same
//  rebuild.
//

import Foundation
import OpenHikesData

nonisolated struct RecordingSegmentLedger: Sendable, Equatable {
    private var builder = RouteSegments.Builder()
    private var previous: RouteCoordinate?
    /// The recording's distance, which the segments add up to.
    private var distanceMeters = 0.0

    /// Every segment so far, the one in progress last, or none until a pause
    /// has cut the walk: one segment is the walk itself, which the figures
    /// above the list already are.
    var shown: [RouteSegment] {
        let reading = builder
        return reading.finish(distanceMeters: distanceMeters)
    }

    /// - Parameter distanceMeters: the recording's distance once `point` is
    ///   counted.
    mutating func record(_ point: RecordingPoint, distanceMeters: Double) {
        let coordinate = point.routeCoordinate
        builder.consume(coordinate, segmentMeters: previous.map(coordinate.legMeters(from:)) ?? 0)
        previous = coordinate
        self.distanceMeters = distanceMeters
    }
}
