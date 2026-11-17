//
//  RecordingSegmentLedger.swift
//  OpenHikes
//
//  The segments a recording's pauses have cut it into so far (#1470).
//
//  A saved hike's segments are read off its route (``RouteSegments``). A
//  recording has no route until Stop, so this keeps the same figures as the
//  walk goes: the running totals as they stood at each resume, and each
//  segment the difference between two of them. That makes the segments add
//  up to the distance, the active time and the climb the screen shows above
//  them, by construction.
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
    /// A recording's running totals at one moment.
    struct Totals: Sendable, Equatable {
        var distanceMeters = 0.0
        /// ``RecordingDistanceAccumulator/recordedDuration``, the clock *Avg
        /// Speed* divides by.
        var seconds = 0.0
        /// `nil` until the recording has two heights to subtract.
        var elevationGainMeters: Double?
    }

    /// The segments a pause has ended, oldest first, each with the length of
    /// the stop that ended it.
    private(set) var finished: [RouteSegment] = []
    /// The totals when the segment in progress began.
    private var base = Totals()
    private var latest = Totals()
    private var previousTimestamp: Date?
    /// When the newest finished segment's last fix was taken, which its stop
    /// is counted from.
    private var finishedEnd: Date?

    /// Every segment so far, the one in progress last, or none until a pause
    /// has cut the walk: one segment is the walk itself, which the figures
    /// above the list already are.
    var shown: [RouteSegment] {
        finished.isEmpty ? [] : finished + [segment(upTo: latest)]
    }

    /// - Parameter totals: the recording's totals once `point` is counted. A
    ///   point a pause arrives at adds nothing to any of them, so they are
    ///   also where the segment before it ended.
    mutating func record(_ point: RecordingPoint, totals: Totals) {
        if point.flags.contains(.resumed), let previousTimestamp {
            let ended = segment(upTo: totals)
            // A lone fix, with a pause on both sides, walked nothing: it is
            // no segment, as it is none on a saved route, and the stop before
            // it runs on through it to this resume.
            if ended.distanceMeters > 0 || (ended.seconds ?? 0) > 0 {
                var closed = ended
                closed.stopSeconds = max(0, point.timestamp.timeIntervalSince(previousTimestamp))
                finished.append(closed)
                finishedEnd = previousTimestamp
            } else if let finishedEnd, !finished.isEmpty {
                finished[finished.count - 1].stopSeconds = max(0, point.timestamp.timeIntervalSince(finishedEnd))
            }
            base = totals
        }
        latest = totals
        previousTimestamp = point.timestamp
    }

    private func segment(upTo totals: Totals) -> RouteSegment {
        RouteSegment(
            // A stationary window hands distance back; never below where the
            // segment began.
            distanceMeters: max(0, totals.distanceMeters - base.distanceMeters),
            seconds: max(0, totals.seconds - base.seconds),
            elevationGainMeters: totals.elevationGainMeters.map { gain in
                max(0, gain - (base.elevationGainMeters ?? 0))
            }
        )
    }
}
